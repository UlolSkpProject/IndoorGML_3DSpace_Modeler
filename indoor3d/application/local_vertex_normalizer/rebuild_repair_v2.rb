# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # Coplanar edge removal is attempted only on a closed rebuilt surface.
        # An open rebuild is left intact for the ordered step-10 repair sequence.
        # If cleanup damages a previously closed shell, the validated triangles
        # are rebuilt before continuing.
        def orient_and_merge_rebuilt_surface(entities, validated_triangles)
          topology_before = geometry_counts(entities)
          consistency = repair_reverse_faces(entities)
          axis_plane_merge = empty_coplanar_cleanup_report
          post_cleanup_snapshot = nil

          if closed_surface?(geometry_counts(entities))
            backup = validated_triangles.map(&:dup)
            begin
              axis_plane_merge = remove_coplanar_shared_edges(
                entities,
                plane_tolerance_mm: STRICT_COPLANAR_TOLERANCE_MM,
                angle_tolerance_deg: STRICT_COPLANAR_ANGLE_TOLERANCE_DEG
              )
              topology = geometry_counts(entities)
              unless closed_surface?(topology)
                raise DestructiveCoplanarCleanupError,
                      "Coplanar cleanup opened rebuilt shell: #{topology.inspect}"
              end

              merged_duplicate_diagnostics = {}
              merged_triangles = normalized_triangle_snapshot(
                entities,
                duplicate_diagnostics: merged_duplicate_diagnostics,
                snapshot_role: :post_coplanar_cleanup
              )
              merged_triangles, merged_degenerate_repair =
                repair_degenerate_source_triangles(
                merged_triangles
              )
              merged_mesh_validation =
                validate_normalized_triangle_mesh!(merged_triangles)
              merged_surface_equivalence = verify_normalized_surface_equivalence!(
                validated_triangles,
                merged_triangles
              )
              post_cleanup_snapshot = {
                validated: true,
                triangles: merged_triangles,
                duplicate_diagnostics: merged_duplicate_diagnostics,
                degenerate_repair: merged_degenerate_repair,
                mesh_validation: merged_mesh_validation,
                surface_equivalence: merged_surface_equivalence,
                topology: topology
              }
            rescue Error, ArgumentError => error
              erase_source_geometry(entities)
              restored = rebuild_triangles(entities, backup)
              unless restored[:added_faces] == backup.length &&
                     restored[:skipped_collinear].zero?
                raise ReconstructionError,
                      "Could not restore surface after coplanar cleanup failure: " \
                      "#{restored.inspect}"
              end
              consistency = repair_reverse_faces(entities)
              axis_plane_merge = empty_coplanar_cleanup_report(
                fallback_reason: "#{error.class}: #{error.message}"
              )
            end
          else
            axis_plane_merge = empty_coplanar_cleanup_report(
              fallback_reason: :skipped_open_rebuilt_surface
            )
          end

          topology_after = geometry_counts(entities)
          orientation = {
            reversed_faces: consistency[:reversed_faces].to_i,
            consistency_reversed_faces:
              consistency[:consistency_reversed_faces].to_i,
            shell_component_count: consistency[:component_count].to_i,
            outward_reversed_faces: consistency[:outward_reversed_faces].to_i,
            signed_volume_before_mm3:
              consistency[:signed_volume_before_in3].to_f * (MM_PER_INCH**3),
            signed_volume_after_mm3:
              consistency[:signed_volume_after_in3].to_f * (MM_PER_INCH**3),
            topology_before: topology_before,
            topology_after: topology_after,
            error: consistency[:error]
          }
          axis_plane_merge[:merged_faces] = axis_plane_merge[:removed_groups] ||
            axis_plane_merge[:removed_edges]
          axis_plane_merge[:preserved_constrained_edges] = false
          [orientation, axis_plane_merge, post_cleanup_snapshot]
        end

        # Step 10. Each repair is bounded and accepted only when it improves the
        # entity topology. As soon as the group is again a manifold solid, later
        # destructive repair attempts are skipped. Geometric equivalence with the
        # validated in-memory surface is checked after this sequence.
        def repair_rebuilt_entity_before_rollback(entity, entities)
          report = {
            attempted: false,
            initial_topology: geometry_counts(entities),
            surface_border: { repairs: 0, skipped: true },
            reverse_faces: { reversed_faces: 0, component_count: 0, skipped: true },
            external_faces: { removed_faces: 0, attempts: 0, skipped: true },
            stray_edges: { removed_edges: 0, skipped: true },
            final_topology: nil,
            manifold: false
          }

          if manifold_entity_with_closed_topology?(entity, report[:initial_topology])
            report[:final_topology] = report[:initial_topology]
            report[:manifold] = true
            return report
          end

          report[:attempted] = true

          report[:surface_border] = attempt_entity_repair_step do
            stitch_surface_borders(entities)
          end
          return finish_entity_repair_report(report, entity, entities) if
            manifold_entity_with_closed_topology?(entity, geometry_counts(entities))

          report[:reverse_faces] = attempt_entity_repair_step do
            repair_reverse_faces(entities)
          end
          return finish_entity_repair_report(report, entity, entities) if
            manifold_entity_with_closed_topology?(entity, geometry_counts(entities))

          report[:external_faces] = attempt_entity_repair_step do
            remove_external_faces_conservatively(entities)
          end
          return finish_entity_repair_report(report, entity, entities) if
            manifold_entity_with_closed_topology?(entity, geometry_counts(entities))

          report[:stray_edges] = attempt_entity_repair_step do
            remove_stray_edges(entities)
          end
          finish_entity_repair_report(report, entity, entities)
        end

        def attempt_entity_repair_step
          result = yield
          (result || {}).merge(skipped: false)
        rescue StandardError => error
          {
            skipped: false,
            error: "#{error.class}: #{error.message}"
          }
        end

        def repair_reverse_faces(entities)
          consistency = orient_shell_faces_consistently(entities)
          outward = if closed_surface?(geometry_counts(entities)) &&
                       consistency[:component_count] == 1
                      orient_shell_outward(entities)
                    else
                      {
                        reversed_faces: 0,
                        signed_volume_before_in3: nil,
                        signed_volume_after_in3: nil
                      }
                    end
          {
            reversed_faces: consistency[:reversed_faces] + outward[:reversed_faces],
            consistency_reversed_faces: consistency[:reversed_faces],
            outward_reversed_faces: outward[:reversed_faces],
            component_count: consistency[:component_count],
            signed_volume_before_in3: outward[:signed_volume_before_in3],
            signed_volume_after_in3: outward[:signed_volume_after_in3]
          }
        rescue TopologyChangedError => error
          {
            reversed_faces: 0,
            component_count: 0,
            error: "#{error.class}: #{error.message}"
          }
        end

        # Removes only faces touching an overused edge and only when a trial
        # deletion strictly reduces the anomaly score. Rejected candidates are
        # restored with their original metadata.
        def remove_external_faces_conservatively(entities)
          removed_faces = 0
          removed_boundary_edges = 0
          attempts = 0
          ignored_signatures = {}

          while attempts < MAX_EXTERNAL_FACE_REPAIRS
            before = geometry_counts(entities)
            candidates = entities.grep(@face_class).select do |face|
              next false unless face&.valid?

              signature = face_signature(face)
              next false if ignored_signatures[signature]

              face.edges.any? { |edge| edge.faces.length > 2 }
            end
            break if candidates.empty?

            accepted = false
            candidates.each do |face|
              break if attempts >= MAX_EXTERNAL_FACE_REPAIRS

              attempts += 1
              signature = face_signature(face)
              record = face_record(face)
              candidate_edges = face.edges.dup
              face.erase!
              removed_candidate_edges = candidate_edges.count do |edge|
                next false unless edge&.valid? && edge.faces.empty?

                edge.erase!
                true
              end
              after = geometry_counts(entities)

              if topology_anomaly_score(after) < topology_anomaly_score(before) &&
                 after[:faces].positive?
                removed_faces += 1
                removed_boundary_edges += removed_candidate_edges
                accepted = true
                break
              end

              restored = entities.add_face(record[:points])
              unless restored&.valid?
                raise ReconstructionError,
                      "External-face trial could not restore rejected face: " \
                      "#{before.inspect} -> #{after.inspect}"
              end
              orient_face!(restored, record[:source_normal])
              apply_face_metadata(restored, record)
              ignored_signatures[signature] = true
            end
            break unless accepted
          end

          {
            removed_faces: removed_faces,
            removed_boundary_edges: removed_boundary_edges,
            attempts: attempts,
            limit_reached: attempts >= MAX_EXTERNAL_FACE_REPAIRS
          }
        end

        def face_signature(face)
          face.vertices.map { |vertex| grid_indices(vertex.position) }.sort
        end

        def remove_stray_edges(entities)
          edges = entities.grep(@edge_class).select do |edge|
            edge&.valid? && edge.faces.empty?
          end
          entities.erase_entities(edges) unless edges.empty?
          { removed_edges: edges.length }
        end

        def manifold_entity_with_closed_topology?(entity, topology)
          entity&.valid? &&
            entity.respond_to?(:manifold?) &&
            entity.manifold? == true &&
            closed_topology?(topology)
        rescue StandardError
          false
        end

        def finish_entity_repair_report(report, entity, entities)
          topology = geometry_counts(entities)
          report[:final_topology] = topology
          report[:manifold] = manifold_entity_with_closed_topology?(entity, topology)
          unless report[:manifold]
            raise TopologyChangedError,
                  "Local vertex reconstruction remained non-manifold after " \
                  "surface-border, reverse-face, external-face, and stray-edge " \
                  "repairs: #{entity_label(entity)} #{topology.inspect}"
          end
          report
        end

        # Manifold alone is insufficient: SketchUp repairs must preserve the exact
        # validated surface. The descriptor ignores internal triangulation and
        # collinear boundary subdivision, but preserves each connected coplanar
        # patch plane and its outer/hole boundary loops.
        def verify_normalized_surface_equivalence!(expected_records, actual_records)
          expected = normalized_surface_descriptor(expected_records)
          actual = normalized_surface_descriptor(actual_records)
          if expected == actual
            return {
              equivalent: true,
              expected_patch_count: expected.length,
              actual_patch_count: actual.length
            }
          end

          missing = expected - actual
          added = actual - expected
          raise TopologyChangedError,
                "Final rebuilt surface differs from validated triangle surface: " \
                "missing_patches=#{missing.length} added_patches=#{added.length} " \
                "missing_sample=#{missing.first(3).inspect} " \
                "added_sample=#{added.first(3).inspect}"
        end

        # Surface equivalence is geometric, not metadata- or triangulation-based.
        # Triangles are clustered with the same strict tolerances used by the
        # post-rebuild coplanar cleanup. Shared edges are split at every collinear
        # vertex so T-junction/subdivided boundaries form one component.
        def normalized_surface_descriptor(triangle_records)
          records = triangle_records.reject do |record|
            triangle = record[:points].map { |point| grid_indices(point) }
            triangle.uniq.length != 3 ||
              integer_zero_vector?(integer_triangle_normal(triangle))
          end

          descriptors = []
          surface_coplanar_clusters(records).each do |plane_records|
            coplanar_geometry_components(plane_records).each do |component|
              edge_owners = split_triangle_edge_owners(component)
              overused = edge_owners.select { |_edge, owners| owners.length > 2 }
              unless overused.empty?
                raise TopologyChangedError,
                      "Surface descriptor found overused coplanar edges: " \
                      "#{overused.first(5).inspect}"
              end

              boundary_edges = edge_owners.filter_map do |edge, owners|
                edge if owners.length == 1
              end
              loops = exact_boundary_loops(boundary_edges).map do |loop|
                canonical_exact_loop(simplify_exact_loop(loop))
              end.sort
              descriptors << [surface_patch_plane_key(loops), loops]
            end
          end
          descriptors.sort
        end

        def surface_coplanar_clusters(records)
          clusters = []
          records.each do |record|
            plane = surface_triangle_plane(record)
            cluster = clusters.find do |entry|
              surface_planes_compatible?(entry[:plane], plane)
            end
            if cluster
              cluster[:records] << record
            else
              clusters << { plane: plane, records: [record] }
            end
          end
          clusters.map { |entry| entry[:records] }
        end

        def surface_triangle_plane(record)
          triangle = record[:points].map { |point| grid_indices(point) }
          normal = integer_triangle_normal(triangle).map(&:to_f)
          length = vector_length(normal)
          if length <= 0.0
            raise TopologyChangedError,
                  "Cannot build surface plane from degenerate triangle: #{triangle.inspect}"
          end

          unit = normal.map { |value| value / length }
          first_nonzero = unit.find { |value| value.abs > 1.0e-15 }
          if first_nonzero&.negative?
            unit = unit.map(&:-@)
          end
          {
            unit_normal: unit,
            offset: vector_dot(unit, triangle[0]),
            triangle: triangle
          }
        end

        def surface_planes_compatible?(first, second)
          dot = vector_dot(first[:unit_normal], second[:unit_normal]).abs
          threshold = Math.cos(
            STRICT_COPLANAR_ANGLE_TOLERANCE_DEG * Math::PI / 180.0
          )
          return false if dot + 1.0e-15 < threshold

          tolerance_grid = STRICT_COPLANAR_TOLERANCE_MM / @tolerance_mm
          surface_plane_deviation_grid(first, second[:triangle]) <= tolerance_grid &&
            surface_plane_deviation_grid(second, first[:triangle]) <= tolerance_grid
        end

        def surface_plane_deviation_grid(plane, triangle)
          triangle.map do |point|
            (vector_dot(plane[:unit_normal], point) - plane[:offset]).abs
          end.max || 0.0
        end

        def coplanar_geometry_components(records)
          edge_owners = split_triangle_edge_owners(records)
          adjacency = Array.new(records.length) { [] }
          edge_owners.each_value do |owners|
            owners.uniq.combination(2) do |first, second|
              adjacency[first] << second
              adjacency[second] << first
            end
          end

          visited = Array.new(records.length, false)
          records.each_index.filter_map do |seed|
            next if visited[seed]

            visited[seed] = true
            queue = [seed]
            component_indices = []
            until queue.empty?
              index = queue.shift
              component_indices << index
              adjacency[index].each do |neighbor|
                next if visited[neighbor]

                visited[neighbor] = true
                queue << neighbor
              end
            end
            component_indices.map { |index| records[index] }
          end
        end

        def split_triangle_edge_owners(records)
          points = records.flat_map do |record|
            record[:points].map { |point| grid_indices(point) }
          end.uniq
          edge_owners = Hash.new { |hash, key| hash[key] = [] }

          records.each_with_index do |record, record_index|
            triangle = record[:points].map { |point| grid_indices(point) }
            3.times do |edge_index|
              point_a = triangle[edge_index]
              point_b = triangle[(edge_index + 1) % 3]
              integer_points_on_segment_sorted(point_a, point_b, points)
                .each_cons(2) do |segment_start, segment_end|
                  next if segment_start == segment_end

                  edge = canonical_edge_key(segment_start, segment_end)
                  edge_owners[edge] << record_index unless
                    edge_owners[edge].include?(record_index)
                end
            end
          end
          edge_owners
        end

        def integer_points_on_segment_sorted(point_a, point_b, candidates)
          direction = integer_subtract(point_b, point_a)
          axis = direction.each_index.max_by { |index| direction[index].abs }
          denominator = direction[axis]
          return [point_a, point_b] if denominator.zero?

          candidates.select do |point|
            point == point_a || point == point_b ||
              integer_point_between?(point, point_a, point_b)
          end.sort_by do |point|
            Rational(point[axis] - point_a[axis], denominator)
          end.uniq
        end

        def surface_patch_plane_key(loops)
          points = loops.flatten(1).uniq.sort
          origin = points.first
          if origin
            (1...points.length).each do |first_index|
              ((first_index + 1)...points.length).each do |second_index|
                triangle = [origin, points[first_index], points[second_index]]
                next if integer_zero_vector?(integer_triangle_normal(triangle))

                return exact_integer_plane_key(triangle)
              end
            end
          end
          raise TopologyChangedError,
                "Surface patch boundary cannot define a plane: #{loops.inspect}"
        end

        def simplify_exact_loop(loop)
          simplified = loop.dup
          changed = true
          while changed && simplified.length > 3
            changed = false
            simplified.each_index do |index|
              previous = simplified[(index - 1) % simplified.length]
              current = simplified[index]
              following = simplified[(index + 1) % simplified.length]
              incoming = integer_subtract(current, previous)
              outgoing = integer_subtract(following, current)
              next unless integer_zero_vector?(integer_cross(incoming, outgoing))
              next unless integer_dot(incoming, outgoing).positive?

              simplified.delete_at(index)
              changed = true
              break
            end
          end
          simplified
        end

        def canonical_exact_loop(loop)
          raise TopologyChangedError, 'Surface boundary loop has fewer than three points' if
            loop.length < 3

          candidates = []
          [loop, loop.reverse].each do |sequence|
            sequence.each_index do |index|
              candidates << sequence[index..] + sequence[0...index]
            end
          end
          candidates.min { |first, second| first <=> second }
        end
      end
    end
  end
end
