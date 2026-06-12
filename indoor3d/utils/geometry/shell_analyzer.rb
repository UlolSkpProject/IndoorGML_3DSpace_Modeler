# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        def self.find_shell_inner_centroid(cell_space_entity)
          center = cell_space_entity.definition.bounds.center
          faces = local_shell_faces(cell_space_entity)
          return center if faces.empty?

          tolerance = SHELL_CENTER_TOLERANCE
          return center if shell_contains_point?(faces, center, tolerance) && shell_distance(faces, center) > tolerance

          best_point, best_distance = best_inner_sample(
            faces,
            cell_space_entity.definition.bounds,
            SHELL_CENTER_COARSE_DIVISIONS,
            tolerance
          )
          return center unless best_point

          refined_point = refined_inner_sample(
            faces,
            cell_space_entity.definition.bounds,
            best_point,
            best_distance,
            SHELL_CENTER_COARSE_DIVISIONS,
            SHELL_CENTER_REFINE_DIVISIONS,
            tolerance
          ).first
          refined_point || best_point || center
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Shell inner centroid failed: #{e.class}: #{e.message}"
          center || cell_space_entity.definition.bounds.center
        end

        #=============================================================================================================#

        def self.local_shell_faces(entity)
          return [] unless entity&.valid?
          return [] unless entity.respond_to?(:definition) && entity.definition&.valid?

          entity.definition.entities.grep(Sketchup::Face).map do |face|
            next unless face&.valid?

            outer = face.outer_loop.vertices.map(&:position)
            next if outer.length < 3

            normal = face.normal
            normal.normalize!
            loops = face.loops.map { |loop| loop.vertices.map(&:position) }
            {
              outer: outer,
              inners: loops.reject { |loop| loop == outer || loop.length < 3 },
              loops: loops.select { |loop| loop.length >= 2 },
              normal: normal,
              plane_point: outer.first,
              axis: dominant_axis(normal)
            }
          end.compact
        end
        private_class_method :local_shell_faces

        def self.shell_contains_point?(faces, point, tolerance)
          votes = shell_ray_directions.count do |direction|
            ray_intersection_count(faces, point, direction, tolerance).odd?
          end
          votes > (shell_ray_directions.length / 2)
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

        def self.ray_intersection_count(faces, point, direction, tolerance)
          distances = faces.filter_map do |face|
            ray_face_intersection_distance(face, point, direction, tolerance)
          end
          unique_sorted_distances(distances, tolerance).length
        end
        private_class_method :ray_intersection_count

        def self.ray_face_intersection_distance(face, point, direction, tolerance)
          denominator = dot_product(face[:normal], direction)
          return nil if denominator.abs <= tolerance

          distance = dot_product(point.vector_to(face[:plane_point]), face[:normal]) / denominator
          return nil if distance <= tolerance

          hit = offset_point(point, direction, distance)
          point_in_face_region?(hit, face, tolerance) ? distance : nil
        end
        private_class_method :ray_face_intersection_distance

        def self.unique_sorted_distances(distances, tolerance)
          distances.sort.each_with_object([]) do |distance, unique|
            unique << distance if unique.empty? || (distance - unique.last).abs > tolerance
          end
        end
        private_class_method :unique_sorted_distances

        def self.best_inner_sample(faces, bounds, divisions, tolerance)
          best_inner_point(faces, shell_sample_points(bounds.min, bounds.max, divisions, include_edges: false), tolerance)
        end
        private_class_method :best_inner_sample

        def self.refined_inner_sample(faces, bounds, point, distance, coarse_divisions, refine_divisions, tolerance)
          step = shell_sample_step(bounds, coarse_divisions)
          min_point = clamp_point_to_bounds(
            Geom::Point3d.new(point.x - step.x, point.y - step.y, point.z - step.z),
            bounds
          )
          max_point = clamp_point_to_bounds(
            Geom::Point3d.new(point.x + step.x, point.y + step.y, point.z + step.z),
            bounds
          )
          best_inner_point(
            faces,
            shell_sample_points(min_point, max_point, refine_divisions, include_edges: true),
            tolerance,
            point,
            distance
          )
        end
        private_class_method :refined_inner_sample

        def self.best_inner_point(faces, points, tolerance, initial_point = nil, initial_distance = nil)
          best_point = initial_point
          best_distance = initial_distance || -Float::INFINITY
          points.each do |point|
            next unless shell_contains_point?(faces, point, tolerance)

            distance = shell_distance(faces, point)
            next if distance <= tolerance || distance <= best_distance

            best_point = point
            best_distance = distance
          end
          [best_point, best_distance]
        end
        private_class_method :best_inner_point

        def self.shell_sample_points(min_point, max_point, divisions, include_edges:)
          ranges = [:x, :y, :z].map do |axis|
            min = min_point.public_send(axis).to_f
            max = max_point.public_send(axis).to_f
            if include_edges
              (0..divisions).map { |index| min + ((max - min) * index / divisions.to_f) }
            else
              (1..divisions).map { |index| min + ((max - min) * index / (divisions + 1).to_f) }
            end
          end

          ranges[0].product(ranges[1], ranges[2]).map { |x, y, z| Geom::Point3d.new(x, y, z) }
        end
        private_class_method :shell_sample_points

        def self.shell_sample_step(bounds, divisions)
          Geom::Vector3d.new(
            (bounds.max.x - bounds.min.x).to_f / (divisions + 1).to_f,
            (bounds.max.y - bounds.min.y).to_f / (divisions + 1).to_f,
            (bounds.max.z - bounds.min.z).to_f / (divisions + 1).to_f
          )
        end
        private_class_method :shell_sample_step

        def self.clamp_point_to_bounds(point, bounds)
          Geom::Point3d.new(
            [[point.x, bounds.min.x].max, bounds.max.x].min,
            [[point.y, bounds.min.y].max, bounds.max.y].min,
            [[point.z, bounds.min.z].max, bounds.max.z].min
          )
        end
        private_class_method :clamp_point_to_bounds

        def self.shell_distance(faces, point)
          faces.map { |face| point_to_face_distance(point, face) }.min || 0.0
        end
        private_class_method :shell_distance

        def self.point_to_face_distance(point, face)
          signed_distance = dot_product(face[:plane_point].vector_to(point), face[:normal])
          projected = offset_point(point, face[:normal], -signed_distance)
          return signed_distance.abs if point_in_face_region?(projected, face, SHELL_CENTER_TOLERANCE)

          face[:loops].flat_map { |loop| loop_edges(loop) }
                      .map { |edge_start, edge_end| point_to_segment_distance(point, edge_start, edge_end) }
                      .min || signed_distance.abs
        end
        private_class_method :point_to_face_distance

        def self.point_in_face_region?(point, face, tolerance)
          point_2d = project_point_for_axis(point, face[:axis])
          outer = face[:outer].map { |vertex| project_point_for_axis(vertex, face[:axis]) }
          return false unless point_in_polygon?(point_2d, outer, tolerance)

          face[:inners].none? do |inner|
            point_in_polygon?(point_2d, inner.map { |vertex| project_point_for_axis(vertex, face[:axis]) }, tolerance)
          end
        end
        private_class_method :point_in_face_region?

        def self.project_point_for_axis(point, axis)
          case axis
          when :x
            [point.y.to_f, point.z.to_f]
          when :y
            [point.x.to_f, point.z.to_f]
          else
            [point.x.to_f, point.y.to_f]
          end
        end
        private_class_method :project_point_for_axis

        def self.loop_edges(loop)
          loop.each_index.map { |index| [loop[index], loop[(index + 1) % loop.length]] }
        end
        private_class_method :loop_edges

        def self.point_to_segment_distance(point, segment_start, segment_end)
          segment = segment_start.vector_to(segment_end)
          length_squared = dot_product(segment, segment)
          return point.distance(segment_start) if length_squared <= 0.000001

          ratio = dot_product(segment_start.vector_to(point), segment) / length_squared
          ratio = [[ratio, 0.0].max, 1.0].min
          point.distance(offset_point(segment_start, segment, ratio))
        end
        private_class_method :point_to_segment_distance

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
