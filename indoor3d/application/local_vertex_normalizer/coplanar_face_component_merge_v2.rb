# frozen_string_literal: true

require_relative 'coplanar_collinear_edge_policy_v2'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Shared implementation for connected near-coplanar Face simplification.
      #
      # This is the single geometry implementation used by both:
      # - dev/lvn_coplanar_face_merge_experiment.rb
      # - LocalVertexNormalizer's final post-normalize pass
      #
      # No caller-specific surface-equivalence rule belongs here. A merge is
      # accepted by the same topology/manifold gates in every caller.
      module CoplanarFaceComponentMergeV2
        MM_PER_INCH = 25.4
        DEFAULT_ANGLE_TOLERANCE_DEG = 0.01
        DEFAULT_PLANE_TOLERANCE_MM = 0.0025

        class MergeError < StandardError; end

        module_function

        def merge!(solid, angle_tolerance_deg: DEFAULT_ANGLE_TOLERANCE_DEG,
                   plane_tolerance_mm: DEFAULT_PLANE_TOLERANCE_MM)
          validate_solid!(solid)

          angle_tolerance_deg = Float(angle_tolerance_deg)
          plane_tolerance_mm = Float(plane_tolerance_mm)
          raise ArgumentError, 'angle_tolerance_deg must be >= 0' if angle_tolerance_deg.negative?
          raise ArgumentError, 'plane_tolerance_mm must be >= 0' if plane_tolerance_mm.negative?

          entities = solid.definition.entities
          initial_topology = coplanar_merge_face_summary(entities)
          initial_manifold = manifold?(solid)
          source_face_count = initial_topology[:faces]
          initial_state = build_merge_plan_state(
            entities,
            angle_tolerance_deg: angle_tolerance_deg,
            plane_tolerance_mm: plane_tolerance_mm
          )
          ring_repair = prepare_ring_self_touch_repair(initial_state[:plans])
          initial_ring_self_touch_vertex_count =
            ring_self_touch_vertex_count(initial_state[:all_faces])
          ring_repair[:ring_self_touch_vertex_count_after] =
            initial_ring_self_touch_vertex_count

          unless ring_repair[:edges].empty?
            entities.erase_entities(ring_repair[:edges])
            repaired_topology = coplanar_merge_face_summary(entities)
            repaired_manifold = manifold?(solid)
            repair_face_reduction =
              initial_topology[:faces] - repaired_topology[:faces]
            if repair_face_reduction != ring_repair[:expected_face_reduction]
              raise MergeError,
                    "Ring self-touch repair merged faces by #{repair_face_reduction}; " \
                    "expected #{ring_repair[:expected_face_reduction]}"
            end
            if initial_topology[:closed] && !repaired_topology[:closed]
              raise MergeError, 'Ring self-touch repair opened a previously closed shell'
            end
            if repaired_topology[:overused_edges] > initial_topology[:overused_edges]
              raise MergeError, 'Ring self-touch repair increased overused-edge count'
            end
            if repaired_topology[:boundary_edges] > initial_topology[:boundary_edges]
              raise MergeError, 'Ring self-touch repair increased boundary-edge count'
            end
            if initial_manifold && !repaired_manifold
              raise MergeError,
                    'Ring self-touch repair changed a manifold solid into non-manifold geometry'
            end

            repaired_faces = entities.grep(Sketchup::Face).select(&:valid?)
            repaired_ring_count = ring_self_touch_vertex_count(repaired_faces)
            if repaired_ring_count >= initial_ring_self_touch_vertex_count
              raise MergeError,
                    'Ring self-touch repair did not reduce repeated outer-loop vertices'
            end
            ring_repair[:actual_face_reduction] = repair_face_reduction
            ring_repair[:ring_self_touch_vertex_count_after] = repaired_ring_count
          end

          # Erasing a shared edge can replace either incident SketchUp Face.
          # Rebuild every component, planar group, and merge plan from entities;
          # no pre-repair Face/Edge reference is safe to reuse here.
          state = build_merge_plan_state(
            entities,
            angle_tolerance_deg: angle_tolerance_deg,
            plane_tolerance_mm: plane_tolerance_mm
          )
          normal_components = state[:normal_components]
          planar_groups = state[:planar_groups]
          plans = state[:plans]

          # Snapshot all Face-derived data before mutation. SketchUp can replace
          # several original Faces with a new n-gon as soon as one edge is erased.
          planned_internal_edges = plans.flat_map { |plan| plan[:internal_edges] }
                                        .uniq
                                        .select(&:valid?)
          protected_lookup = {}
          plans.each do |plan|
            protection =
              CoplanarCollinearEdgePolicyV2.protected_fan_transition_edges(
                faces: plan[:faces],
                internal_edges: plan[:internal_edges],
                removal_edges: planned_internal_edges,
                angle_tolerance_deg: angle_tolerance_deg
              )
            protection[:edges].each do |edge|
              protected_lookup[stable_entity_id(edge)] = edge
            end
            plan[:fan_transition_vertex_ids] =
              protection[:fan_transition_vertex_ids]
          end

          plans.each do |plan|
            plan[:deletable_internal_edges] = plan[:internal_edges].reject do |edge|
              protected_lookup[stable_entity_id(edge)]
            end
            plan[:protected_internal_edge_count] =
              plan[:internal_edges].length - plan[:deletable_internal_edges].length
            plan[:expected_face_reduction] = merge_face_reduction_for_edges(
              plan[:faces],
              plan[:deletable_internal_edges]
            )
          end
          all_internal_edges = plans.flat_map do |plan|
            plan[:deletable_internal_edges]
          end.uniq.select(&:valid?)
          merge_seed_vertices = all_internal_edges.flat_map do |edge|
            Array(edge.vertices)
          end.uniq
          expected_face_reduction =
            ring_repair[:expected_face_reduction] +
            plans.sum { |plan| plan[:expected_face_reduction] }

          entities.erase_entities(all_internal_edges) unless all_internal_edges.empty?

          collapse_report =
            CoplanarCollinearEdgePolicyV2.collapse_degree_two_collinear_vertices!(
              entities,
              merge_seed_vertices,
              angle_tolerance_deg: angle_tolerance_deg
            )

          final_topology = coplanar_merge_face_summary(entities)
          final_manifold = manifold?(solid)
          actual_face_reduction = initial_topology[:faces] - final_topology[:faces]

          if actual_face_reduction != expected_face_reduction
            raise MergeError,
                  "Merged faces by #{actual_face_reduction}; expected #{expected_face_reduction}"
          end
          if initial_topology[:closed] && !final_topology[:closed]
            raise MergeError, 'Coplanar face merge opened a previously closed shell'
          end
          if final_topology[:overused_edges] > initial_topology[:overused_edges]
            raise MergeError, 'Coplanar face merge increased overused-edge count'
          end
          if final_topology[:boundary_edges] > initial_topology[:boundary_edges]
            raise MergeError, 'Coplanar face merge increased boundary-edge count'
          end
          if initial_manifold && !final_manifold
            raise MergeError,
                  'Coplanar face merge changed a manifold solid into non-manifold geometry'
          end

          {
            angle_tolerance_deg: angle_tolerance_deg,
            plane_tolerance_mm: plane_tolerance_mm,
            source_face_count: source_face_count,
            normal_component_count: normal_components.length,
            planar_group_count: planar_groups.length,
            singleton_group_count: planar_groups.count { |group| group.length == 1 },
            merge_group_count:
              ring_repair[:bundles].length +
              plans.count { |plan| plan[:expected_face_reduction].positive? },
            protected_merge_group_count: plans.count do |plan|
              plan[:protected_internal_edge_count].positive?
            end,
            merged_input_face_count: plans.sum do |plan|
              plan[:expected_face_reduction].positive? ? plan[:input_face_count] : 0
            end,
            removed_internal_edge_count:
              ring_repair[:edges].length + all_internal_edges.length,
            ring_self_touch_repair_bundle_count: ring_repair[:bundles].length,
            ring_self_touch_repair_edge_count: ring_repair[:edges].length,
            ring_self_touch_repair_expected_face_reduction:
              ring_repair[:expected_face_reduction],
            ring_self_touch_repair_actual_face_reduction:
              ring_repair[:actual_face_reduction],
            ring_self_touch_vertex_count_before:
              initial_ring_self_touch_vertex_count,
            ring_self_touch_vertex_count_after:
              ring_repair[:ring_self_touch_vertex_count_after],
            ring_self_touch_repairs: ring_repair[:bundles].map do |bundle|
              bundle.reject { |key, _value| key == :edges }
            end,
            protected_fan_transition_edge_count: protected_lookup.length,
            collapsed_collinear_vertex_count:
              collapse_report[:collapsed_vertex_count],
            collapsed_collinear_vertex_ids:
              collapse_report[:collapsed_vertex_ids],
            expected_face_reduction: expected_face_reduction,
            actual_face_reduction: actual_face_reduction,
            initial_topology: initial_topology,
            final_topology: final_topology,
            initial_manifold: initial_manifold,
            final_manifold: final_manifold,
            groups: plans.map do |plan|
              plan.reject do |key, _value|
                %i[faces internal_edges deletable_internal_edges].include?(key)
              end
            end
          }
        end

        def build_merge_plan_state(entities, angle_tolerance_deg:, plane_tolerance_mm:)
          all_faces = entities.grep(Sketchup::Face).select(&:valid?)
          face_by_id = all_faces.to_h { |face| [stable_entity_id(face), face] }
          unvisited = face_by_id.keys.to_h { |face_id| [face_id, true] }
          normal_components = []

          until unvisited.empty?
            seed_id = unvisited.keys.first
            seed = face_by_id[seed_id]
            unless seed&.valid?
              unvisited.delete(seed_id)
              next
            end

            component = collect_normal_component(
              seed,
              allowed_ids: unvisited,
              angle_tolerance_deg: angle_tolerance_deg
            )
            component.each { |face| unvisited.delete(stable_entity_id(face)) }
            normal_components << component unless component.empty?
          end

          planar_groups = normal_components.flat_map do |component|
            refine_component_by_best_fit(
              component,
              angle_tolerance_deg: angle_tolerance_deg,
              plane_tolerance_mm: plane_tolerance_mm
            )
          end
          merge_groups = planar_groups
                         .select { |group| group.length > 1 }
                         .sort_by do |group|
                           [-group.length, group.map { |face| stable_entity_id(face) }.min]
                         end
          plans = merge_groups.map.with_index do |group, index|
            prepare_merge_plan(group, ordinal: index + 1, total: merge_groups.length)
          end

          {
            all_faces: all_faces,
            normal_components: normal_components,
            planar_groups: planar_groups,
            plans: plans
          }
        end

        def prepare_ring_self_touch_repair(plans)
          bundles = Array(plans).flat_map do |plan|
            CoplanarCollinearEdgePolicyV2.ring_self_touch_repair_edge_bundles(
              faces: plan[:faces],
              internal_edges: plan[:internal_edges]
            )
          end
          bundles = bundles.each_with_object({}) do |bundle, result|
            result[bundle[:edge_ids]] ||= bundle
          end.values
          edges = bundles.flat_map { |bundle| bundle[:edges] }.uniq.select(&:valid?)
          expected_face_reduction = Array(plans).sum do |plan|
            plan_edges = edges.select do |edge|
              Array(edge.faces).all? do |face|
                plan[:faces].include?(face)
              end
            end
            merge_face_reduction_for_edges(plan[:faces], plan_edges)
          end

          {
            bundles: bundles,
            edges: edges,
            expected_face_reduction: expected_face_reduction,
            actual_face_reduction: 0,
            ring_self_touch_vertex_count_after: nil
          }
        end

        def ring_self_touch_vertex_count(faces)
          Array(faces).sum do |face|
            CoplanarCollinearEdgePolicyV2
              .repeated_outer_loop_vertices(face)
              .length
          end
        end

        # Implicit BFS. SketchUp Face/Edge incidence is the graph.
        def collect_normal_component(seed, allowed_ids:, angle_tolerance_deg:)
          seed_id = stable_entity_id(seed)
          return [] unless allowed_ids[seed_id]

          queued = { seed_id => true }
          queue = [seed]
          component = []
          cursor = 0

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
              next unless normal_angle_within?(face, neighbor, angle_tolerance_deg)

              queued[neighbor_id] = true
              queue << neighbor
            end
          end

          component
        end

        def implicit_subcomponents(faces, angle_tolerance_deg:)
          valid_faces = faces.select(&:valid?).uniq
          face_by_id = valid_faces.to_h { |face| [stable_entity_id(face), face] }
          remaining = face_by_id.keys.to_h { |face_id| [face_id, true] }
          components = []

          until remaining.empty?
            seed_id = remaining.keys.first
            seed = face_by_id[seed_id]
            unless seed&.valid?
              remaining.delete(seed_id)
              next
            end

            component = collect_normal_component(
              seed,
              allowed_ids: remaining,
              angle_tolerance_deg: angle_tolerance_deg
            )
            component.each { |face| remaining.delete(stable_entity_id(face)) }
            components << component unless component.empty?
          end

          components
        end

        # Partition one normal-connected component into connected patches whose
        # every vertex lies within plane_tolerance_mm of the patch best-fit plane.
        def refine_component_by_best_fit(faces, angle_tolerance_deg:, plane_tolerance_mm:)
          faces = faces.select(&:valid?).uniq
          return [] if faces.empty?
          return [faces] if faces.length == 1

          metrics = best_fit_component_metrics(faces)
          return faces.map { |face| [face] } unless metrics

          bad = faces.select do |face|
            metrics[:face_max_deviation_mm].fetch(
              stable_entity_id(face),
              Float::INFINITY
            ) > plane_tolerance_mm
          end
          return [faces] if bad.empty?

          keep = faces - bad
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
          implicit_subcomponents(keep, angle_tolerance_deg: angle_tolerance_deg).each do |subcomponent|
            result.concat(
              refine_component_by_best_fit(
                subcomponent,
                angle_tolerance_deg: angle_tolerance_deg,
                plane_tolerance_mm: plane_tolerance_mm
              )
            )
          end
          implicit_subcomponents(bad, angle_tolerance_deg: angle_tolerance_deg).each do |subcomponent|
            result.concat(
              refine_component_by_best_fit(
                subcomponent,
                angle_tolerance_deg: angle_tolerance_deg,
                plane_tolerance_mm: plane_tolerance_mm
              )
            )
          end
          result
        end

        def best_fit_component_metrics(faces)
          valid_faces = faces.select(&:valid?).uniq
          vertices = valid_faces.flat_map(&:vertices).select(&:valid?).uniq
          return nil if vertices.length < 3

          plane = Geom.fit_plane_to_points(vertices.map(&:position))
          return nil unless plane && plane.length == 4

          a, b, c, d = plane.map(&:to_f)
          norm = Math.sqrt((a * a) + (b * b) + (c * c))
          return nil if norm <= 1.0e-15

          face_max = {}
          max_deviation = 0.0
          valid_faces.each do |face|
            deviation = face.vertices.map do |vertex|
              point_plane_distance_mm(vertex.position, [a, b, c, d], norm)
            end.max || 0.0
            face_max[stable_entity_id(face)] = deviation
            max_deviation = [max_deviation, deviation].max
          end

          {
            plane: [a, b, c, d],
            plane_norm: norm,
            vertex_count: vertices.length,
            max_vertex_deviation_mm: max_deviation,
            face_max_deviation_mm: face_max
          }
        rescue StandardError
          nil
        end

        def point_plane_distance_mm(point, plane, norm = nil)
          a, b, c, d = plane
          denominator = norm || Math.sqrt((a * a) + (b * b) + (c * c))
          return Float::INFINITY if denominator <= 1.0e-15

          numerator = (
            (a * point.x.to_f) +
            (b * point.y.to_f) +
            (c * point.z.to_f) +
            d
          ).abs
          numerator * MM_PER_INCH / denominator
        end

        def normal_angle_within?(face_a, face_b, tolerance_deg)
          angle = normal_angle_deg(face_a, face_b)
          !angle.nil? && angle <= tolerance_deg
        end

        def normal_angle_deg(face_a, face_b)
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

        def prepare_merge_plan(faces, ordinal:, total:)
          current_faces = faces.select(&:valid?).uniq
          unless current_faces.length == faces.length
            raise MergeError, "Merge group #{ordinal}/#{total} changed before planning"
          end

          descriptor = describe_planar_group(current_faces)
          face_ids = current_faces.to_h { |face| [stable_entity_id(face), true] }
          internal_edges = current_faces.flat_map(&:edges).uniq.select do |edge|
            next false unless edge&.valid? && edge.faces.length == 2

            face_a, face_b = edge.faces
            face_ids[stable_entity_id(face_a)] && face_ids[stable_entity_id(face_b)]
          end
          if internal_edges.empty?
            raise MergeError, "Merge group #{ordinal}/#{total} has no internal shared edges"
          end

          {
            index: ordinal,
            total: total,
            faces: current_faces,
            face_ids: descriptor[:face_ids],
            input_face_count: current_faces.length,
            input_vertex_count: descriptor[:vertex_count],
            internal_edges: internal_edges,
            internal_edge_count: internal_edges.length,
            expected_face_reduction: current_faces.length - 1,
            max_adjacent_angle_deg: descriptor[:max_adjacent_angle_deg],
            max_vertex_deviation_mm: descriptor[:max_vertex_deviation_mm]
          }
        end

        def merge_face_reduction_for_edges(faces, edges)
          valid_faces = Array(faces).select(&:valid?).uniq
          return 0 if valid_faces.length < 2

          face_lookup = valid_faces.to_h do |face|
            [stable_entity_id(face), face]
          end
          adjacency = Hash.new { |hash, key| hash[key] = [] }
          Array(edges).each do |edge|
            next unless edge&.valid?

            owners = Array(edge.faces).select do |face|
              face_lookup[stable_entity_id(face)]
            end
            next unless owners.length == 2

            first = stable_entity_id(owners[0])
            second = stable_entity_id(owners[1])
            adjacency[first] << second
            adjacency[second] << first
          end

          visited = {}
          component_count = 0
          face_lookup.each_key do |seed|
            next if visited[seed]

            component_count += 1
            visited[seed] = true
            queue = [seed]
            until queue.empty?
              current = queue.shift
              adjacency[current].each do |neighbor|
                next if visited[neighbor]

                visited[neighbor] = true
                queue << neighbor
              end
            end
          end

          valid_faces.length - component_count
        end

        def describe_planar_group(faces)
          metrics = best_fit_component_metrics(faces)
          {
            face_ids: faces.select(&:valid?).map { |face| stable_entity_id(face) }.sort,
            face_count: faces.count(&:valid?),
            vertex_count: metrics ? metrics[:vertex_count] : 0,
            max_vertex_deviation_mm:
              metrics ? metrics[:max_vertex_deviation_mm] : Float::INFINITY,
            max_adjacent_angle_deg: max_adjacent_angle_deg(faces)
          }
        end

        def max_adjacent_angle_deg(faces)
          valid_faces = faces.select(&:valid?).uniq
          allowed = valid_faces.to_h { |face| [stable_entity_id(face), true] }
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
              angle = normal_angle_deg(face_a, face_b)
              angles << angle if angle
            end
          end

          angles.max || 0.0
        end

        def coplanar_merge_face_summary(entities)
          faces = entities.grep(Sketchup::Face).select(&:valid?)
          edges = entities.grep(Sketchup::Edge).select(&:valid?)
          boundary_edges = edges.count { |edge| edge.faces.length == 1 }
          overused_edges = edges.count { |edge| edge.faces.length > 2 }
          {
            faces: faces.length,
            edges: edges.length,
            boundary_edges: boundary_edges,
            overused_edges: overused_edges,
            stray_edges: edges.count { |edge| edge.faces.empty? },
            closed: faces.any? && boundary_edges.zero? && overused_edges.zero?
          }
        end

        def validate_solid!(solid)
          unless solid&.valid? && solid.respond_to?(:definition) &&
                 solid.respond_to?(:manifold?) && solid.manifold? == true
            raise ArgumentError, 'A valid manifold Group/ComponentInstance is required'
          end
        end

        def manifold?(solid)
          solid.respond_to?(:manifold?) && solid.manifold? == true
        rescue StandardError
          false
        end

        def stable_entity_id(entity)
          return entity.persistent_id if entity.respond_to?(:persistent_id)

          entity.object_id
        rescue StandardError
          entity.object_id
        end

        def vector_components(vector)
          [vector.x.to_f, vector.y.to_f, vector.z.to_f]
        end

        def vector_dot(first, second)
          (first[0] * second[0]) + (first[1] * second[1]) + (first[2] * second[2])
        end

        def vector_length(vector)
          Math.sqrt(vector_dot(vector, vector))
        end
      end
    end
  end
end
