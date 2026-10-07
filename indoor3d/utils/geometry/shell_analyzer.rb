# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        # Retained for source-shell classification. State interior-point search is
        # Native-only and is not implemented in Ruby.
        def self.shell_contains_point_in_faces?(faces, point, tolerance = SHELL_CENTER_TOLERANCE)
          records = shell_face_records(faces)
          return false if records.empty?

          shell_contains_point?(records, point, tolerance)
        end

        def self.shell_face_records(faces)
          ray_directions = shell_ray_directions
          Array(faces).map do |face|
            next unless face&.valid?

            outer = face.outer_loop.vertices.map(&:position)
            next if outer.length < 3

            normal = face.normal
            normal.normalize!
            loops = face.loops.map { |loop| loop.vertices.map(&:position) }
            inners = loops.reject { |loop| loop == outer || loop.length < 3 }
            axis = dominant_axis(normal)
            {
              outer_2d: outer.map { |vertex| project_point_for_axis(vertex, axis) },
              inners_2d: inners.map do |loop|
                loop.map { |vertex| project_point_for_axis(vertex, axis) }
              end,
              ray_denominators: ray_directions.map do |direction|
                dot_product(normal, direction)
              end,
              normal: normal,
              plane_point: outer.first,
              axis: axis
            }
          end.compact
        end
        private_class_method :shell_face_records

        def self.shell_contains_point?(faces, point, tolerance)
          directions = shell_ray_directions
          required_votes = (directions.length / 2) + 1
          inside_votes = 0

          directions.each_with_index do |direction, index|
            inside_votes += 1 if ray_intersection_count(
              faces,
              point,
              direction,
              tolerance,
              ray_index: index
            ).odd?
            return true if inside_votes >= required_votes

            remaining = directions.length - index - 1
            return false if inside_votes + remaining < required_votes
          end
          false
        end
        private_class_method :shell_contains_point?

        def self.shell_ray_directions
          @shell_ray_directions ||= [
            Geom::Vector3d.new(1.0, 0.371, 0.113),
            Geom::Vector3d.new(0.271, 1.0, 0.619),
            Geom::Vector3d.new(0.433, 0.197, 1.0)
          ].each { |direction| direction.normalize! }
        end
        private_class_method :shell_ray_directions

        def self.ray_intersection_count(faces, point, direction, tolerance, ray_index: nil)
          distances = faces.filter_map do |face|
            ray_face_intersection_distance(
              face,
              point,
              direction,
              tolerance,
              ray_index: ray_index
            )
          end
          unique_sorted_distances(distances, tolerance).length
        end
        private_class_method :ray_intersection_count

        def self.ray_face_intersection_distance(face, point, direction, tolerance, ray_index: nil)
          denominator = if ray_index && face[:ray_denominators]
                          face[:ray_denominators][ray_index]
                        else
                          dot_product(face[:normal], direction)
                        end
          return nil if denominator.abs <= tolerance

          distance =
            dot_product(point.vector_to(face[:plane_point]), face[:normal]) / denominator
          return nil if distance <= tolerance

          hit = offset_point(point, direction, distance)
          point_in_face_region?(hit, face, tolerance) ? distance : nil
        end
        private_class_method :ray_face_intersection_distance

        def self.unique_sorted_distances(distances, tolerance)
          return distances if distances.length < 2

          distances.sort!
          write_index = 1
          last_distance = distances.first
          (1...distances.length).each do |read_index|
            distance = distances[read_index]
            next if (distance - last_distance).abs <= tolerance

            distances[write_index] = distance
            write_index += 1
            last_distance = distance
          end
          if write_index < distances.length
            distances.slice!(write_index, distances.length - write_index)
          end
          distances
        end
        private_class_method :unique_sorted_distances

        def self.point_in_face_region?(point, face, tolerance)
          point_2d = project_point_for_axis(point, face[:axis])
          return false unless point_in_polygon?(point_2d, face[:outer_2d], tolerance)

          face[:inners_2d].none? do |inner|
            point_in_polygon?(point_2d, inner, tolerance)
          end
        end
        private_class_method :point_in_face_region?

        def self.project_point_for_axis(point, axis)
          case axis
          when :x then [point.y.to_f, point.z.to_f]
          when :y then [point.x.to_f, point.z.to_f]
          else [point.x.to_f, point.y.to_f]
          end
        end
        private_class_method :project_point_for_axis

        def self.offset_point(point, direction, distance)
          Geom::Point3d.new(
            point.x + (direction.x * distance),
            point.y + (direction.y * distance),
            point.z + (direction.z * distance)
          )
        end
        private_class_method :offset_point
      end
    end
  end
end
