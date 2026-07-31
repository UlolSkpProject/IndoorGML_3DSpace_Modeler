# frozen_string_literal: true

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
          all_faces = entities.grep(Sketchup::Face).select(&:valid?)
          source_face_count = all_faces.length

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

          initial_topology = coplanar_merge_face_summary(entities)
          initial_manifold = manifold?(solid)
          plans = merge_groups.map.with_index do |group, index|
            prepare_merge_plan(group, ordinal: index + 1, total: merge_groups.length)
          end

          # Snapshot all Face-derived data before mutation. SketchUp can replace
          # several original Faces with a new n-gon as soon as one edge is erased.
          all_internal_edges = plans.flat_map { |plan| plan[:internal_edges] }
                                    .uniq
                                    .select(&:valid?)
          expected_face_reduction = plans.sum { |plan| plan[:expected_face_reduction] }

          entities.erase_entities(all_internal_edges) unless all_internal_edges.empty?

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
            merge_group_count: merge_groups.length,
            merged_input_face_count: plans.sum { |plan| plan[:input_face_count] },
            removed_internal_edge_count: all_internal_edges.length,
            expected_face_reduction: expected_face_reduction,
            actual_face_reduction: actual_face_reduction,
            initial_topology: initial_topology,
            final_topology: final_topology,
            initial_manifold: initial_manifold,
            final_manifold: final_manifold,
            groups: plans.map { |plan| plan.reject { |key, _value| key == :internal_edges } }
          }
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
