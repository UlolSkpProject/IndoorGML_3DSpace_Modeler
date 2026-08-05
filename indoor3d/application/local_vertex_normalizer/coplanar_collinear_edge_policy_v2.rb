# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Topology policy shared by both coplanar Face-merge implementations.
      #
      # A coplanar internal edge is not redundant when removing it would leave a
      # straight-through vertex in the merged Face while another surface edge
      # still branches from that vertex. CGAL's convex decomposition can fail on
      # that otherwise-manifold representation. Preserve every internal edge at
      # such a fan-transition vertex.
      #
      # Conversely, when only two collinear manifold edges remain and they have
      # the same Face fan, the middle vertex is a pure edge subdivision. Rebuild
      # the two incident Faces without that vertex, replacing A-V/V-C by A-C.
      module CoplanarCollinearEdgePolicyV2
        DEFAULT_STRAIGHT_ANGLE_TOLERANCE_DEG = 0.001
        COLLAPSE_DISTANCE_TOLERANCE_INCHES = 1.0e-8

        class CollapseError < StandardError; end

        module_function

        def protected_fan_transition_edges(
          faces:,
          internal_edges:,
          removal_edges: internal_edges,
          angle_tolerance_deg: DEFAULT_STRAIGHT_ANGLE_TOLERANCE_DEG
        )
          valid_faces = Array(faces).select { |face| valid_entity?(face) }.uniq
          valid_internal_edges = Array(internal_edges).select do |edge|
            valid_entity?(edge)
          end.uniq
          removal_lookup = Array(removal_edges).each_with_object({}) do |edge, result|
            result[stable_entity_id(edge)] = true if valid_entity?(edge)
          end
          face_lookup = valid_faces.each_with_object({}) do |face, result|
            result[stable_entity_id(face)] = true
          end

          protected = {}
          fan_vertices = []
          candidate_vertices = valid_internal_edges.flat_map do |edge|
            Array(edge.vertices)
          end.uniq

          candidate_vertices.each do |vertex|
            next unless valid_entity?(vertex)

            incident = Array(vertex.edges).select { |edge| valid_entity?(edge) }
            surviving = incident.reject do |edge|
              removal_lookup[stable_entity_id(edge)]
            end
            boundary = surviving.select do |edge|
              Array(edge.faces).count do |face|
                face_lookup[stable_entity_id(face)]
              end == 1
            end
            next unless boundary.length == 2
            next unless straight_through_vertex?(
              vertex,
              boundary[0],
              boundary[1],
              angle_tolerance_deg: angle_tolerance_deg
            )
            # With only the two boundary edges left, V is a pure subdivision and
            # is intentionally handled by the post-merge collapse pass.
            next unless surviving.length > 2

            incident.each do |edge|
              next unless valid_internal_edges.include?(edge)

              protected[stable_entity_id(edge)] = edge
            end
            fan_vertices << stable_entity_id(vertex)
          end

          {
            edges: protected.values,
            edge_count: protected.length,
            fan_transition_vertex_ids: fan_vertices.uniq.sort,
            fan_transition_vertex_count: fan_vertices.uniq.length
          }
        end

        def fan_transition_vertices(
          entities,
          face_class: nil,
          angle_tolerance_deg: DEFAULT_STRAIGHT_ANGLE_TOLERANCE_DEG
        )
          face_class ||= Sketchup::Face if defined?(Sketchup::Face)
          faces = face_class ? entities.grep(face_class) : []
          result = {}
          faces.each do |face|
            next unless valid_entity?(face) && face.respond_to?(:loops)

            Array(face.loops).each do |loop|
              vertices = Array(loop.vertices)
              next if vertices.length < 3

              vertices.each_index do |index|
                vertex = vertices[index]
                next unless valid_entity?(vertex)

                incident = Array(vertex.edges).select { |edge| valid_entity?(edge) }
                next unless incident.length > 2

                previous = vertices[(index - 1) % vertices.length]
                following = vertices[(index + 1) % vertices.length]
                first = edge_between(vertex, previous)
                second = edge_between(vertex, following)
                next unless first && second
                next unless straight_through_vertex?(
                  vertex,
                  first,
                  second,
                  angle_tolerance_deg: angle_tolerance_deg
                )

                result[stable_entity_id(vertex)] = vertex
              end
            end
          end
          result.values
        end

        def collapse_degree_two_collinear_vertices!(
          entities,
          vertices,
          angle_tolerance_deg: DEFAULT_STRAIGHT_ANGLE_TOLERANCE_DEG
        )
          collapsed_ids = []
          skipped_ids = []

          Array(vertices).uniq.sort_by { |vertex| stable_entity_id(vertex) }.each do |vertex|
            context = degree_two_collinear_context(
              vertex,
              angle_tolerance_deg: angle_tolerance_deg
            )
            next unless context

            records = context[:faces].map do |face|
              face_record_without_vertex(face, vertex)
            end
            if records.any?(&:nil?)
              skipped_ids << stable_entity_id(vertex)
              next
            end

            vertex_id = stable_entity_id(vertex)
            context[:faces].each(&:erase!)
            context[:edges].each do |edge|
              edge.erase! if valid_entity?(edge) && Array(edge.faces).empty?
            end

            rebuilt = records.map do |record|
              face = add_or_find_face(
                entities,
                record[:points],
                context[:faces].first.class
              )
              unless valid_entity?(face)
                raise CollapseError,
                      "Could not rebuild Face while collapsing collinear vertex #{vertex_id}"
              end

              orient_face_like!(face, record[:normal])
              apply_face_metadata(face, record)
              face
            end
            unless rebuilt.length == records.length
              raise CollapseError,
                    "Incomplete Face rebuild while collapsing collinear vertex #{vertex_id}"
            end

            collapsed_ids << vertex_id
          end

          {
            collapsed_vertex_count: collapsed_ids.length,
            collapsed_vertex_ids: collapsed_ids,
            skipped_vertex_count: skipped_ids.length,
            skipped_vertex_ids: skipped_ids
          }
        end

        def degree_two_collinear_context(
          vertex,
          angle_tolerance_deg: DEFAULT_STRAIGHT_ANGLE_TOLERANCE_DEG
        )
          return nil unless valid_entity?(vertex)

          edges = Array(vertex.edges).select { |edge| valid_entity?(edge) }
          return nil unless edges.length == 2
          return nil unless edges.all? { |edge| Array(edge.faces).length == 2 }
          return nil unless same_face_fan?(edges[0], edges[1])
          return nil unless straight_through_vertex?(
            vertex,
            edges[0],
            edges[1],
            angle_tolerance_deg: angle_tolerance_deg
          )
          return nil unless point_segment_distance_inches(
            vertex.position,
            opposite_vertex(edges[0], vertex).position,
            opposite_vertex(edges[1], vertex).position
          ) <= COLLAPSE_DISTANCE_TOLERANCE_INCHES

          faces = Array(edges[0].faces).select { |face| valid_entity?(face) }
          return nil unless faces.length == 2

          { vertex: vertex, edges: edges, faces: faces }
        end

        def same_face_fan?(first, second)
          first_ids = Array(first.faces).map { |face| stable_entity_id(face) }.sort
          second_ids = Array(second.faces).map { |face| stable_entity_id(face) }.sort
          first_ids.length == 2 && first_ids == second_ids
        end

        def straight_through_vertex?(
          vertex,
          first_edge,
          second_edge,
          angle_tolerance_deg: DEFAULT_STRAIGHT_ANGLE_TOLERANCE_DEG
        )
          first_point = opposite_vertex(first_edge, vertex)&.position
          second_point = opposite_vertex(second_edge, vertex)&.position
          origin = vertex.respond_to?(:position) ? vertex.position : nil
          return false unless first_point && second_point && origin

          first = vector_between(origin, first_point)
          second = vector_between(origin, second_point)
          denominator = vector_length(first) * vector_length(second)
          return false unless denominator.positive?

          cosine = vector_dot(first, second) / denominator
          threshold = -Math.cos(Float(angle_tolerance_deg) * Math::PI / 180.0)
          cosine <= threshold
        rescue ArgumentError, TypeError
          false
        end

        def face_record_without_vertex(face, vertex)
          return nil unless valid_entity?(face)
          return nil unless face.respond_to?(:loops) && Array(face.loops).length == 1
          return nil unless face.respond_to?(:outer_loop)

          vertices = Array(face.outer_loop.vertices)
          return nil unless vertices.count { |candidate| candidate == vertex } == 1

          points = vertices.reject { |candidate| candidate == vertex }.map(&:position)
          return nil if points.length < 3

          {
            points: points,
            normal: vector_components(face.normal),
            material: face.respond_to?(:material) ? face.material : nil,
            back_material: face.respond_to?(:back_material) ? face.back_material : nil,
            layer: face.respond_to?(:layer) ? face.layer : nil
          }
        rescue StandardError
          nil
        end

        def apply_face_metadata(face, record)
          face.material = record[:material] if face.respond_to?(:material=)
          face.back_material = record[:back_material] if face.respond_to?(:back_material=)
          face.layer = record[:layer] if face.respond_to?(:layer=) && record[:layer]
        end

        def add_or_find_face(entities, points, face_class)
          face = entities.add_face(points)
          return face if valid_entity?(face)
          return nil unless entities.respond_to?(:grep)

          signature = point_signature(points)
          entities.grep(face_class).find do |candidate|
            valid_entity?(candidate) &&
              candidate.respond_to?(:outer_loop) &&
              point_signature(candidate.outer_loop.vertices.map(&:position)) == signature
          end
        end

        def orient_face_like!(face, source_normal)
          return unless face.respond_to?(:normal)

          current = vector_components(face.normal)
          face.reverse! if vector_dot(current, source_normal).negative? &&
                           face.respond_to?(:reverse!)
        end

        def edge_between(first, second)
          Array(first.edges).find do |edge|
            valid_entity?(edge) && Array(edge.vertices).include?(second)
          end
        end

        def opposite_vertex(edge, vertex)
          Array(edge.vertices).find { |candidate| candidate != vertex }
        end

        def vector_between(first, second)
          [
            second.x.to_f - first.x.to_f,
            second.y.to_f - first.y.to_f,
            second.z.to_f - first.z.to_f
          ]
        end

        def vector_components(vector)
          [vector.x.to_f, vector.y.to_f, vector.z.to_f]
        end

        def vector_dot(first, second)
          (first[0] * second[0]) +
            (first[1] * second[1]) +
            (first[2] * second[2])
        end

        def vector_length(vector)
          Math.sqrt(vector_dot(vector, vector))
        end

        def point_segment_distance_inches(point, first, second)
          segment = vector_between(first, second)
          offset = vector_between(first, point)
          length_squared = vector_dot(segment, segment)
          return Float::INFINITY unless length_squared.positive?

          parameter = vector_dot(offset, segment) / length_squared
          return Float::INFINITY unless parameter > 0.0 && parameter < 1.0

          projection = [
            first.x.to_f + (segment[0] * parameter),
            first.y.to_f + (segment[1] * parameter),
            first.z.to_f + (segment[2] * parameter)
          ]
          Math.sqrt(
            ((point.x.to_f - projection[0])**2) +
            ((point.y.to_f - projection[1])**2) +
            ((point.z.to_f - projection[2])**2)
          )
        end

        def point_signature(points)
          Array(points).map do |point|
            [point.x.to_f, point.y.to_f, point.z.to_f]
          end.sort
        end

        def valid_entity?(entity)
          entity && (!entity.respond_to?(:valid?) || entity.valid?)
        rescue StandardError
          false
        end

        def stable_entity_id(entity)
          return entity.persistent_id if entity.respond_to?(:persistent_id)

          entity.object_id
        rescue StandardError
          entity.object_id
        end
      end
    end
  end
end
