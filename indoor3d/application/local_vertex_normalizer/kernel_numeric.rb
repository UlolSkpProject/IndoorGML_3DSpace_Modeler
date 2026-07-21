# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # ----------------------------------------------------------------------
        # Numeric helpers
        # ----------------------------------------------------------------------

        def normalized_target(point, axis_plane_plan = nil)
          indices = grid_indices(point)
          constraints = axis_plane_plan && axis_plane_plan[:constraints]
          (constraints && constraints[source_point_key(point)] || {}).each do |axis, target_index|
            indices[axis] = target_index
          end
          @point_factory.call(
            indices[0] * @tolerance_mm / MM_PER_INCH,
            indices[1] * @tolerance_mm / MM_PER_INCH,
            indices[2] * @tolerance_mm / MM_PER_INCH
          )
        end

        def source_point_key(point)
          [point.x.to_f, point.y.to_f, point.z.to_f]
        end

        def point_coordinate(point, axis)
          [point.x.to_f, point.y.to_f, point.z.to_f].fetch(axis)
        end

        def grid_indices(point)
          [point.x, point.y, point.z].map do |coordinate|
            ((coordinate.to_f * MM_PER_INCH) / @tolerance_mm).round
          end
        end

        def point_on_grid?(point)
          [point.x, point.y, point.z].all? do |coordinate|
            coordinate_mm = coordinate.to_f * MM_PER_INCH
            target_mm = (coordinate_mm / @tolerance_mm).round * @tolerance_mm
            (coordinate_mm - target_mm).abs <= GRID_EPSILON_MM
          end
        end

        def max_grid_residual_mm(vertices)
          vertices.flat_map do |vertex|
            point = vertex.position
            [point.x, point.y, point.z].map do |coordinate|
              coordinate_mm = coordinate.to_f * MM_PER_INCH
              target_mm = (coordinate_mm / @tolerance_mm).round * @tolerance_mm
              (coordinate_mm - target_mm).abs
            end
          end.max || 0.0
        end

        def point_on_segment_parameter(point, start_point, end_point, tolerance_mm)
          ab = [
            end_point.x.to_f - start_point.x.to_f,
            end_point.y.to_f - start_point.y.to_f,
            end_point.z.to_f - start_point.z.to_f
          ]
          ap = [
            point.x.to_f - start_point.x.to_f,
            point.y.to_f - start_point.y.to_f,
            point.z.to_f - start_point.z.to_f
          ]

          length_squared = vector_dot(ab, ab)
          return nil if length_squared.zero?

          parameter = vector_dot(ap, ab) / length_squared
          return nil unless parameter > 1.0e-9 && parameter < (1.0 - 1.0e-9)

          projection = [
            start_point.x.to_f + (ab[0] * parameter),
            start_point.y.to_f + (ab[1] * parameter),
            start_point.z.to_f + (ab[2] * parameter)
          ]

          distance_mm = Math.sqrt(
            ((point.x.to_f - projection[0])**2) +
            ((point.y.to_f - projection[1])**2) +
            ((point.z.to_f - projection[2])**2)
          ) * MM_PER_INCH

          distance_mm <= tolerance_mm ? parameter : nil
        end

        def collinear_triangle?(points)
          return true unless points.length == 3

          ab = vector_between(points[0], points[1])
          ac = vector_between(points[0], points[2])
          vector_length(vector_cross(ab, ac)) <= COLLINEAR_CROSS_EPSILON_IN2
        end

        def point_distance_mm(point_a, point_b)
          Math.sqrt(
            ((point_a.x.to_f - point_b.x.to_f)**2) +
            ((point_a.y.to_f - point_b.y.to_f)**2) +
            ((point_a.z.to_f - point_b.z.to_f)**2)
          ) * MM_PER_INCH
        end

        def point_components_mm(point)
          [point.x.to_f, point.y.to_f, point.z.to_f].map do |value|
            value * MM_PER_INCH
          end
        end

        def vector_components(vector)
          [vector.x.to_f, vector.y.to_f, vector.z.to_f]
        end

        def vector_between(point_a, point_b)
          [
            point_b.x.to_f - point_a.x.to_f,
            point_b.y.to_f - point_a.y.to_f,
            point_b.z.to_f - point_a.z.to_f
          ]
        end

        def vector_dot(vector_a, vector_b)
          (vector_a[0] * vector_b[0]) +
            (vector_a[1] * vector_b[1]) +
            (vector_a[2] * vector_b[2])
        end

        def vector_cross(vector_a, vector_b)
          [
            (vector_a[1] * vector_b[2]) - (vector_a[2] * vector_b[1]),
            (vector_a[2] * vector_b[0]) - (vector_a[0] * vector_b[2]),
            (vector_a[0] * vector_b[1]) - (vector_a[1] * vector_b[0])
          ]
        end

        def vector_length(vector)
          Math.sqrt(vector_dot(vector, vector))
        end

        def solid_volume_mm3(entity)
          entity.volume.to_f * (MM_PER_INCH**3)
        rescue StandardError
          nil
        end
      end
    end
  end
end
