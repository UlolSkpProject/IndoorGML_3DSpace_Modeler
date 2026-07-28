# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        # Final post-normalize Face simplification.
        #
        # This is deliberately separate from STRICT_COPLANAR_TOLERANCE_MM, which
        # is still used by the legacy post-rebuild cleanup and exact surface
        # descriptor code. The final n-gon cleanup uses a component-level
        # best-fit plane instead of pairwise Face planes.
        FINAL_COPLANAR_FACE_PLANE_TOLERANCE_MM = 0.0025 unless
          const_defined?(:FINAL_COPLANAR_FACE_PLANE_TOLERANCE_MM, false)
        FINAL_COPLANAR_FACE_ANGLE_TOLERANCE_DEG = 0.01 unless
          const_defined?(:FINAL_COPLANAR_FACE_ANGLE_TOLERANCE_DEG, false)

        private

        unless private_method_defined?(:normalize_entity_before_final_coplanar_face_merge_v2)
          alias_method :normalize_entity_before_final_coplanar_face_merge_v2,
                       :normalize_entity
        end

        # Run only after the existing normalize pipeline has completed every
        # reconstruction/repair/exact-equivalence check. The surrounding
        # normalization operation still owns rollback, so any failure here rolls
        # the whole normalization back rather than leaving a partially simplified
        # solid.
        def normalize_entity(entity)
          report = normalize_entity_before_final_coplanar_face_merge_v2(entity)
          entities = entity.definition.entities

          topology_before = geometry_counts(entities)
          unless manifold_entity_with_closed_topology?(entity, topology_before)
            raise TopologyChangedError,
                  "Final coplanar Face merge requires a closed manifold solid: " \
                  "#{entity_label(entity)} #{topology_before.inspect}"
          end

          baseline_duplicate_diagnostics = {}
          baseline_triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: baseline_duplicate_diagnostics,
            snapshot_role: :before_final_coplanar_face_merge
          )
          baseline_triangles, baseline_cleanup =
            discard_collapsed_triangle_records(baseline_triangles)
          baseline_mesh_validation =
            validate_normalized_triangle_mesh!(baseline_triangles)

          merge_report = merge_final_coplanar_face_components!(
            entity,
            entities,
            plane_tolerance_mm: FINAL_COPLANAR_FACE_PLANE_TOLERANCE_MM,
            angle_tolerance_deg: FINAL_COPLANAR_FACE_ANGLE_TOLERANCE_DEG
          )

          topology_after = geometry_counts(entities)
          validate_rebuilt_entity!(entity, topology_after)

          final_vertices = geometry_vertices(entities)
          residual_mm = max_grid_residual_mm(final_vertices)
          if residual_mm > GRID_EPSILON_MM
            raise TopologyChangedError,
                  "Final coplanar Face merge moved vertices off the " \
                  "#{@tolerance_mm} mm grid: residual=#{residual_mm} mm"
          end

          final_duplicate_diagnostics = {}
          final_triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: final_duplicate_diagnostics,
            snapshot_role: :after_final_coplanar_face_merge
          )
          final_triangles, final_cleanup =
            discard_collapsed_triangle_records(final_triangles)
          final_mesh_validation =
            validate_normalized_triangle_mesh!(final_triangles)
          surface_equivalence = verify_normalized_surface_equivalence!(
            baseline_triangles,
            final_triangles
          )

          merge_report[:baseline_triangle_cleanup] = baseline_cleanup
          merge_report[:final_triangle_cleanup] = final_cleanup
          merge_report[:baseline_mesh_validation] = baseline_mesh_validation
          merge_report[:final_mesh_validation] = final_mesh_validation
          merge_report[:surface_equivalence] = surface_equivalence
          merge_report[:baseline_duplicate_diagnostics] = baseline_duplicate_diagnostics
          merge_report[:final_duplicate_diagnostics] = final_duplicate_diagnostics
          merge_report[:grid_residual_mm] = residual_mm

          report[:final_coplanar_face_merge] = merge_report if report.is_a?(Hash)
          report
        end

        # No explicit adjacency graph is materialized. SketchUp's own topology is
        # the graph: Face#edges -> Edge#faces. All Face arities participate.
        def merge_final_coplanar_face_components!(
          entity,
          entities,
          plane_tolerance_mm:,
          angle_tolerance_deg:
        )
          all_faces = entities.grep(@face_class).select(&:valid?)
          topology_before = geometry_counts(entities)
          manifold_before = entity.respond_to?(:manifold?) && entity.manifold? == true

          face_by_id = all_faces.to_h do |face|
            [stable_entity_id(face), face]
          end
          unvisited = face_by_id.keys.to_h { |face_id| [face_id, true] }
          normal_components = []

          until unvisited.empty?
            seed_id = unvisited.keys.first
            seed = face_by_id[seed_id]
            unless seed&.valid?
              unvisited.delete(seed_id)
              next
            end

            component = collect_final_coplanar_normal_component(
              seed,
              allowed_ids: unvisited,
              angle_tolerance_deg: angle_tolerance_deg
            )
            component.each do |face|
              unvisited.delete(stable_entity_id(face))
            end
            normal_components << component unless component.empty?
          end

          planar_groups = normal_components.flat_map do |component|
            refine_final_coplanar_component(
              component,
              angle_tolerance_deg: angle_tolerance_deg,
              plane_tolerance_mm: plane_tolerance_mm
            )
          end

          merge_groups = planar_groups
                         .select { |group| group.length > 1 }
                         .sort_by do |group|
                           [-group.length,
                            group.map { |face| stable_entity_id(face) }.min]
                         end

          plans = merge_groups.map.with_index do |group, index|
            prepare_final_coplanar_merge_plan(
              group,
              ordinal: index + 1,
              total: merge_groups.length
            )
          end

          # Important: all Face-derived data is snapshotted before mutation.
          # Deleting one internal edge can invalidate several original Face
          # references when SketchUp replaces them with an n-gon.
          internal_edges = plans.flat_map { |plan| plan[:internal_edges] }
                                .uniq
                                .select(&:valid?)
          expected_face_reduction = plans.sum do |plan|
            plan[:expected_face_reduction]
          end

          entities.erase_entities(internal_edges) unless internal_edges.empty?

          topology_after = geometry_counts(entities)
          actual_face_reduction =
            topology_before[:faces] - topology_after[:faces]

          unless actual_face_reduction == expected_face_reduction
            raise DestructiveCoplanarCleanupError,
                  "Final coplanar Face merge reduced faces by " \
                  "#{actual_face_reduction}; expected " \
                  "#{expected_face_reduction}"
          end

          if closed_surface?(topology_before) && !closed_surface?(topology_after)
            raise DestructiveCoplanarCleanupError,
                  "Final coplanar Face merge opened the shell: " \
                  "#{topology_before.inspect} -> #{topology_after.inspect}"
          end

          if topology_anomaly_score(topology_after) >
             topology_anomaly_score(topology_before)
            raise DestructiveCoplanarCleanupError,
                  "Final coplanar Face merge increased topology anomalies: " \
                  "#{topology_before.inspect} -> #{topology_after.inspect}"
          end

          manifold_after = entity.respond_to?(:manifold?) && entity.manifold? == true
          if manifold_before && !manifold_after
            raise DestructiveCoplanarCleanupError,
                  'Final coplanar Face merge changed a manifold solid into non-manifold geometry'
          end

          {
            plane_tolerance_mm: plane_tolerance_mm,
            angle_tolerance_deg: angle_tolerance_deg,
            source_face_count: all_faces.length,
            normal_component_count: normal_components.length,
            planar_group_count: planar_groups.length,
            singleton_group_count:
              planar_groups.count { |group| group.length == 1 },
            merge_group_count: merge_groups.length,
            merged_input_face_count:
              plans.sum { |plan| plan[:input_face_count] },
            removed_internal_edge_count: internal_edges.length,
            expected_face_reduction: expected_face_reduction,
            actual_face_reduction: actual_face_reduction,
            topology_before: topology_before,
            topology_after: topology_after,
            manifold_before: manifold_before,
            manifold_after: manifold_after,
            groups: plans.map do |plan|
              plan.reject { |key, _value| key == :internal_edges }
            end
          }
        end

        def collect_final_coplanar_normal_component(
          seed,
          allowed_ids:,
          angle_tolerance_deg:
        )
          seed_id = stable_entity_id(seed)
          return [] unless allowed_ids[seed_id]

          queued = { seed_id => true }
          queue = [seed]
          cursor = 0
          component = []

          while cursor < queue.length
            face = queue[cursor]
            cursor += 1
            next unless face&.valid?

            component << face
            face.edges.each do |edge|
              next unless edge&.valid? && edge.faces.length == 2

              neighbor = edge.faces.find { |candidate| candidate != face }
              next unless neighbor&.valid?

              neighbor_id = stable_entity_id(neighbor)
              next unless allowed_ids[neighbor_id]
              next if queued[neighbor_id]
              next unless final_coplanar_normal_angle_within?(
                face,
                neighbor,
                angle_tolerance_deg
              )

              queued[neighbor_id] = true
              queue << neighbor
            end
          end

          component
        end

        def final_coplanar_subcomponents(faces, angle_tolerance_deg:)
          valid_faces = faces.select(&:valid?).uniq
          face_by_id = valid_faces.to_h do |face|
            [stable_entity_id(face), face]
          end
          remaining = face_by_id.keys.to_h { |face_id| [face_id, true] }
          components = []

          until remaining.empty?
            seed_id = remaining.keys.first
            seed = face_by_id[seed_id]
            unless seed&.valid?
              remaining.delete(seed_id)
              next
            end

            component = collect_final_coplanar_normal_component(
              seed,
              allowed_ids: remaining,
              angle_tolerance_deg: angle_tolerance_deg
            )
            component.each do |face|
              remaining.delete(stable_entity_id(face))
            end
            components << component unless component.empty?
          end

          components
        end

        def refine_final_coplanar_component(
          faces,
          angle_tolerance_deg:,
          plane_tolerance_mm:
        )
          faces = faces.select(&:valid?).uniq
          return [] if faces.empty?
          return [faces] if faces.length == 1

          metrics = final_coplanar_best_fit_metrics(faces)
          return faces.map { |face| [face] } unless metrics

          bad = faces.select do |face|
            metrics[:face_max_deviation_mm].fetch(
              stable_entity_id(face),
              Float::INFINITY
            ) > plane_tolerance_mm
          end
          return [faces] if bad.empty?

          keep = faces - bad

          # If a broad chained-normal component makes every Face fail the first
          # fit, peel only the worst Face. This guarantees progress and allows
          # smaller valid planar patches to emerge on subsequent fits.
          if keep.empty?
            worst = faces.max_by do |face|
              metrics[:face_max_deviation_mm].fetch(
                stable_entity_id(face),
                Float::INFINITY
              )
            end
            bad = [worst]
            keep = faces - bad
          end

          result = []
          final_coplanar_subcomponents(
            keep,
            angle_tolerance_deg: angle_tolerance_deg
          ).each do |subcomponent|
            result.concat(
              refine_final_coplanar_component(
                subcomponent,
                angle_tolerance_deg: angle_tolerance_deg,
                plane_tolerance_mm: plane_tolerance_mm
              )
            )
          end

          final_coplanar_subcomponents(
            bad,
            angle_tolerance_deg: angle_tolerance_deg
          ).each do |subcomponent|
            result.concat(
              refine_final_coplanar_component(
                subcomponent,
                angle_tolerance_deg: angle_tolerance_deg,
                plane_tolerance_mm: plane_tolerance_mm
              )
            )
          end

          result
        end

        def final_coplanar_best_fit_metrics(faces)
          valid_faces = faces.select(&:valid?).uniq
          vertices = valid_faces.flat_map(&:vertices).select(&:valid?).uniq
          return nil if vertices.length < 3

          plane = Geom.fit_plane_to_points(vertices.map(&:position))
          return nil unless plane && plane.length == 4

          a, b, c, d = plane.map(&:to_f)
          norm = Math.sqrt((a * a) + (b * b) + (c * c))
          return nil if norm <= 1.0e-15

          face_max = {}
          max_deviation_mm = 0.0
          valid_faces.each do |face|
            deviation_mm = face.vertices.map do |vertex|
              final_coplanar_point_plane_distance_mm(
                vertex.position,
                [a, b, c, d],
                norm
              )
            end.max || 0.0
            face_max[stable_entity_id(face)] = deviation_mm
            max_deviation_mm = [max_deviation_mm, deviation_mm].max
          end

          {
            vertex_count: vertices.length,
            max_vertex_deviation_mm: max_deviation_mm,
            face_max_deviation_mm: face_max
          }
        rescue StandardError
          nil
        end

        def final_coplanar_point_plane_distance_mm(point, plane, norm)
          a, b, c, d = plane
          return Float::INFINITY if norm <= 1.0e-15

          numerator = (
            (a * point.x.to_f) +
            (b * point.y.to_f) +
            (c * point.z.to_f) +
            d
          ).abs
          numerator * MM_PER_INCH / norm
        end

        def final_coplanar_normal_angle_within?(face_a, face_b, tolerance_deg)
          angle_deg = final_coplanar_normal_angle_deg(face_a, face_b)
          !angle_deg.nil? && angle_deg <= tolerance_deg
        end

        def final_coplanar_normal_angle_deg(face_a, face_b)
          return nil unless face_a&.valid? && face_b&.valid?

          first = vector_components(face_a.normal)
          second = vector_components(face_b.normal)
          denominator = vector_length(first) * vector_length(second)
          return nil unless denominator.positive?

          cosine = vector_dot(first, second) / denominator
          return nil unless cosine.positive?

          cosine = [[cosine, -1.0].max, 1.0].min
          Math.acos(cosine) * 180.0 / Math::PI
        rescue StandardError
          nil
        end

        def prepare_final_coplanar_merge_plan(faces, ordinal:, total:)
          current_faces = faces.select(&:valid?).uniq
          unless current_faces.length == faces.length
            raise DestructiveCoplanarCleanupError,
                  "Final coplanar merge group #{ordinal}/#{total} changed before planning"
          end

          metrics = final_coplanar_best_fit_metrics(current_faces)
          unless metrics
            raise DestructiveCoplanarCleanupError,
                  "Final coplanar merge group #{ordinal}/#{total} has no valid best-fit plane"
          end

          face_ids = current_faces.to_h do |face|
            [stable_entity_id(face), true]
          end
          internal_edges = current_faces.flat_map(&:edges).uniq.select do |edge|
            next false unless edge&.valid? && edge.faces.length == 2

            face_a, face_b = edge.faces
            face_ids[stable_entity_id(face_a)] &&
              face_ids[stable_entity_id(face_b)]
          end

          if internal_edges.empty?
            raise DestructiveCoplanarCleanupError,
                  "Final coplanar merge group #{ordinal}/#{total} has no internal shared edges"
          end

          max_angle_deg = final_coplanar_max_adjacent_angle_deg(current_faces)
          {
            index: ordinal,
            total: total,
            face_ids:
              current_faces.map { |face| stable_entity_id(face) }.sort,
            input_face_count: current_faces.length,
            input_vertex_count: metrics[:vertex_count],
            internal_edges: internal_edges,
            internal_edge_count: internal_edges.length,
            expected_face_reduction: current_faces.length - 1,
            max_adjacent_angle_deg: max_angle_deg,
            max_vertex_deviation_mm: metrics[:max_vertex_deviation_mm]
          }
        end

        def final_coplanar_max_adjacent_angle_deg(faces)
          valid_faces = faces.select(&:valid?).uniq
          allowed = valid_faces.to_h do |face|
            [stable_entity_id(face), true]
          end
          seen_edges = {}
          angles = []

          valid_faces.each do |face|
            face.edges.each do |edge|
              next unless edge&.valid? && edge.faces.length == 2

              edge_id = stable_entity_id(edge)
              next if seen_edges[edge_id]

              face_a, face_b = edge.faces
              next unless allowed[stable_entity_id(face_a)] &&
                          allowed[stable_entity_id(face_b)]

              seen_edges[edge_id] = true
              angle_deg = final_coplanar_normal_angle_deg(face_a, face_b)
              angles << angle_deg if angle_deg
            end
          end

          angles.max || 0.0
        end
      end
    end
  end
end
