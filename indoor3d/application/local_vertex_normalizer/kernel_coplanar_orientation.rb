# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # ----------------------------------------------------------------------
        # Coplanar and orientation cleanup
        # ----------------------------------------------------------------------

        def face_plane_deviation_mm(source_face, reference_face)
          plane = reference_face.plane.map(&:to_f)
          denominator = Math.sqrt(
            (plane[0]**2) + (plane[1]**2) + (plane[2]**2)
          )
          return Float::INFINITY if denominator.zero?

          source_face.vertices.map do |vertex|
            point = vertex.position
            numerator = (
              (plane[0] * point.x.to_f) +
              (plane[1] * point.y.to_f) +
              (plane[2] * point.z.to_f) +
              plane[3]
            ).abs
            numerator * MM_PER_INCH / denominator
          end.max || 0.0
        end

        def orient_shell_faces_consistently(entities)
          visited = {}
          reversed_faces = 0
          component_count = 0

          entities.grep(@face_class).each do |seed|
            next unless seed.valid?

            seed_id = stable_entity_id(seed)
            next if visited[seed_id]

            component_count += 1
            visited[seed_id] = true
            queue = [seed]

            until queue.empty?
              face = queue.shift
              face.edges.each do |edge|
                next unless edge.valid? && edge.faces.length == 2

                neighbor = (edge.faces - [face]).first
                next unless neighbor&.valid?

                neighbor_id = stable_entity_id(neighbor)
                conflict = edge.reversed_in?(face) == edge.reversed_in?(neighbor)

                if visited[neighbor_id]
                  if conflict
                    raise TopologyChangedError,
                          "Closed shell is not consistently orientable at " \
                          "edge #{stable_entity_id(edge)}"
                  end
                  next
                end

                if conflict
                  neighbor.reverse!
                  reversed_faces += 1
                end

                visited[neighbor_id] = true
                queue << neighbor
              end
            end
          end

          {
            reversed_faces: reversed_faces,
            component_count: component_count
          }
        end

        # A consistently oriented shell can still have every face pointing
        # inward. Positive signed volume is the project-wide outward convention.
        # Relative coordinates keep the determinant stable for station models
        # whose local coordinates are far from the global origin.
        def orient_shell_outward(entities)
          faces = entities.grep(@face_class).select(&:valid?)
          signed_volume_before = shell_signed_volume_in3(faces)
          if signed_volume_before.abs <= SIGNED_VOLUME_EPSILON_IN3
            raise TopologyChangedError,
                  "Closed shell has zero signed volume: #{signed_volume_before} in3"
          end

          reversed_faces = 0
          if signed_volume_before.negative?
            faces.each do |face|
              next unless face.valid?

              face.reverse!
              reversed_faces += 1
            end
          end

          signed_volume_after = shell_signed_volume_in3(faces)
          if signed_volume_after <= SIGNED_VOLUME_EPSILON_IN3
            raise TopologyChangedError,
                  "Closed shell is not outward after orientation: " \
                  "#{signed_volume_after} in3"
          end

          {
            reversed_faces: reversed_faces,
            signed_volume_before_in3: signed_volume_before,
            signed_volume_after_in3: signed_volume_after
          }
        end

        def shell_signed_volume_in3(faces)
          reference = shell_volume_reference_point(faces)
          unless reference
            raise TopologyChangedError, 'Closed shell has no mesh points for orientation'
          end

          faces.sum do |face|
            mesh = face.mesh(0)
            mesh.polygons.sum do |polygon|
              points = polygon.map { |index| mesh.point_at(index.abs) }
              next 0.0 if points.length < 3

              origin = points.first
              (1...(points.length - 1)).sum do |index|
                relative_signed_tetrahedron_volume_in3(
                  reference,
                  origin,
                  points[index],
                  points[index + 1]
                )
              end
            end
          end
        end

        def shell_volume_reference_point(faces)
          faces.each do |face|
            mesh = face.mesh(0)
            point = mesh.point_at(1)
            return point if point
          end

          nil
        end

        def relative_signed_tetrahedron_volume_in3(reference, point_a, point_b, point_c)
          vector_a = vector_between(reference, point_a)
          vector_b = vector_between(reference, point_b)
          vector_c = vector_between(reference, point_c)
          vector_dot(vector_a, vector_cross(vector_b, vector_c)) / 6.0
        end

        def orient_face!(face, source_normal)
          current_normal = vector_components(face.normal)
          face.reverse! if vector_dot(current_normal, source_normal).negative?
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
