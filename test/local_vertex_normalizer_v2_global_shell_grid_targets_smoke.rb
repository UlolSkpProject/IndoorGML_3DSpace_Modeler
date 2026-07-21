# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        class TopologyChangedError < StandardError; end

        def initialize
          @tolerance_mm = 0.001
        end

        private

        def axis_plane_normalization_plan(_entities)
          {}
        end

        def topology_grid_target_candidates(source_mm, constraints, current_target)
          axes = 3.times.map do |axis|
            if constraints.key?(axis)
              [constraints.fetch(axis)]
            else
              scaled = source_mm[axis] / @tolerance_mm
              [scaled.floor, scaled.ceil].uniq
            end
          end
          axes[0].product(axes[1], axes[2])
                 .reject { |target| target == current_target }
                 .sort_by do |target|
            [topology_grid_target_displacement_mm(source_mm, target), target]
          end
        end

        def topology_target_collision_signature(targets)
          owners = Hash.new { |hash, target| hash[target] = [] }
          targets.each { |source_key, target| owners[target] << source_key }
          owners.values.flat_map do |keys|
            keys.length < 2 ? [] : keys.sort.combination(2).to_a
          end
        end

        def topology_grid_target_displacement_mm(source_mm, target)
          Math.sqrt(
            3.times.sum do |axis|
              delta = source_mm[axis] - (target[axis] * @tolerance_mm)
              delta * delta
            end
          )
        end

        def topology_face_embedding_analysis(_face, _targets)
          { valid: true }
        end

        def integer_aabbs_overlap?(first, second)
          3.times.all? do |axis|
            first_range = first.map { |point| point[axis] }.minmax
            second_range = second.map { |point| point[axis] }.minmax
            first_range[0] <= second_range[1] &&
              second_range[0] <= first_range[1]
          end
        end

        def exact_triangle_intersection_allowed?(first, second)
          shared = first & second
          normal_first = integer_triangle_normal(first)
          normal_second = integer_triangle_normal(second)
          direction = integer_cross(normal_first, normal_second)
          raise 'fixture unexpectedly became coplanar' if
            integer_zero_vector?(direction)

          first_interval = triangle_plane_parameter_interval(
            first,
            second[0],
            normal_second,
            direction
          )
          second_interval = triangle_plane_parameter_interval(
            second,
            first[0],
            normal_first,
            direction
          )
          return true unless first_interval && second_interval

          overlap_min = [first_interval[0], second_interval[0]].max
          overlap_max = [first_interval[1], second_interval[1]].min
          return true if overlap_min > overlap_max

          expected = shared.map do |point|
            integer_dot(direction, point)
          end.minmax
          return false if expected.nil?

          overlap_min == expected[0] && overlap_max == expected[1]
        end

        def triangle_plane_parameter_interval(
          triangle,
          plane_point,
          plane_normal,
          direction
        )
          signs = triangle.map do |point|
            integer_dot(
              plane_normal,
              integer_subtract(point, plane_point)
            )
          end
          return nil if signs.all?(&:positive?) ||
                        signs.all?(&:negative?)

          parameters = []
          3.times do |index|
            first = triangle[index]
            second = triangle[(index + 1) % 3]
            first_sign = signs[index]
            second_sign = signs[(index + 1) % 3]
            parameters << Rational(
              integer_dot(direction, first),
              1
            ) if first_sign.zero?
            next unless (
              first_sign.positive? && second_sign.negative?
            ) || (
              first_sign.negative? && second_sign.positive?
            )

            parameter =
              Rational(first_sign, first_sign - second_sign)
            first_value = integer_dot(direction, first)
            second_value = integer_dot(direction, second)
            parameters << (
              first_value +
              (parameter * (second_value - first_value))
            )
          end
          parameters.uniq.minmax unless parameters.empty?
        end

        def integer_triangle_normal(triangle)
          integer_cross(
            integer_subtract(triangle[1], triangle[0]),
            integer_subtract(triangle[2], triangle[0])
          )
        end

        def integer_subtract(first, second)
          [
            first[0] - second[0],
            first[1] - second[1],
            first[2] - second[2]
          ]
        end

        def integer_dot(first, second)
          (first[0] * second[0]) +
            (first[1] * second[1]) +
            (first[2] * second[2])
        end

        def integer_cross(first, second)
          [
            (first[1] * second[2]) - (first[2] * second[1]),
            (first[2] * second[0]) - (first[0] * second[2]),
            (first[0] * second[1]) - (first[1] * second[0])
          ]
        end

        def integer_zero_vector?(vector)
          vector.all?(&:zero?)
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/global_shell_embedding_grid_targets_v2'

klass =
  ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
normalizer = klass.new

source_mm = {
  a0: [-4725.910952512647, -25148.288664470605, -460.96257121549763],
  shared: [-4717.263873031754, -24858.417826399298, 4089.058977449562],
  a2: [-4725.911585939026, -25148.28933533337, 4089.0569598112857],
  b0: [-7483.174664296633, -24775.901348478445, 4017.618081561479],
  b1: [-4811.239032748629, -28008.445048426067, 4089.0370348791303]
}

triangles = [
  {
    source_keys: %i[a0 shared a2],
    source_face_key: :first_face,
    source_polygon_index: 0
  },
  {
    source_keys: %i[b0 b1 shared],
    source_face_key: :second_face,
    source_polygon_index: 0
  }
]

nearest_targets = source_mm.transform_values do |point|
  point.map { |coordinate| (coordinate / 0.001).round }
end
source_coordinates = source_mm.transform_values do |point|
  point.map { |coordinate| (coordinate * 1_000_000).round }
end

baseline = normalizer.send(
  :global_shell_intersection_pairs,
  triangles,
  source_coordinates
)
raise "source fixture intersects: #{baseline.inspect}" unless baseline.empty?

introduced = normalizer.send(
  :global_shell_new_intersection_pairs,
  triangles,
  nearest_targets,
  baseline
)
unless introduced.keys == [[0, 1]]
  raise "nearest rounding did not introduce one intersection: #{introduced.inspect}"
end

repaired, report = normalizer.send(
  :repair_global_shell_grid_targets,
  [],
  triangles,
  nearest_targets,
  source_mm,
  {},
  baseline
)

remaining = normalizer.send(
  :global_shell_new_intersection_pairs,
  triangles,
  repaired,
  baseline
)
raise "repair left a new shell intersection: #{remaining.inspect}" unless
  remaining.empty?
unless report[:global_shell_initial_new_intersection_count] == 1
  raise "initial shell intersection count missing: #{report.inspect}"
end
unless report[:global_shell_repaired_source_point_count].positive?
  raise "solver did not change a grid target: #{report.inspect}"
end

puts 'LocalVertexNormalizer global shell grid target smoke test: OK'
