# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        STRICT_COPLANAR_TOLERANCE_MM = 0.0001
        GLOBAL_SHELL_SOURCE_SCALE_PER_MM = 1_000_000

        class TopologyChangedError < StandardError; end

        def initialize
          @tolerance_mm = 0.001
        end

        private

        def axis_plane_normalization_plan(_entities)
          {}
        end

        def global_shell_record_indices_by_source_key(_records)
          Hash.new { |hash, key| hash[key] = [] }
        end

        def global_shell_triangle_indices_by_source_key(_records)
          Hash.new { |hash, key| hash[key] = [] }
        end

        def topology_target_collision_signature(targets)
          owners = Hash.new { |hash, key| hash[key] = [] }
          targets.each { |key, target| owners[target] << key }
          owners.values.flat_map do |keys|
            keys.length < 2 ? [] : keys.combination(2).to_a
          end
        end

        def topology_grid_target_candidates(source_mm, constraints, current)
          per_axis = 3.times.map do |axis|
            if constraints.key?(axis)
              [constraints.fetch(axis)]
            else
              scaled = source_mm[axis] / @tolerance_mm
              [scaled.floor, scaled.ceil].uniq
            end
          end

          per_axis[0]
            .product(per_axis[1], per_axis[2])
            .reject { |target| target == current }
            .sort_by do |target|
              [
                topology_grid_target_displacement_mm(source_mm, target),
                target
              ]
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

        def global_shell_intersection_pairs(
          _records,
          _coordinates,
          impacted_triangles: nil
        )
          impacted_triangles
          {}
        end

        def integer_point_between?(point, first, second)
          direction = integer_subtract(second, first)
          offset = integer_subtract(point, first)
          return false unless integer_cross(direction, offset).all?(&:zero?)
          return false if point == first || point == second

          3.times.all? do |axis|
            point[axis] >= [first[axis], second[axis]].min &&
              point[axis] <= [first[axis], second[axis]].max
          end
        end

        def integer_subtract(first, second)
          [
            first[0] - second[0],
            first[1] - second[1],
            first[2] - second[2]
          ]
        end

        def integer_cross(first, second)
          [
            (first[1] * second[2]) - (first[2] * second[1]),
            (first[2] * second[0]) - (first[0] * second[2]),
            (first[0] * second[1]) - (first[1] * second[0])
          ]
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/boundary_incidence_grid_targets_v2'

klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
normalizer = klass.new

# The source point is exactly halfway along the source edge. Independent nearest
# 0.001 mm rounding makes the three integer targets non-collinear. The generic
# incidence solver must select adjacent floor/ceil targets that restore the
# vertex-on-edge relation without any PID or model-coordinate special branch.
source_mm = {
  edge_a: [0.0, 0.00049, 0.0],
  edge_b: [2.0, 0.00149, 0.0],
  point: [1.0, 0.00099, 0.0]
}
targets = source_mm.transform_values do |point|
  point.map { |coordinate| (coordinate / 0.001).round }
end
incidences = [{
  vertex_key: :point,
  edge_first_key: :edge_a,
  edge_second_key: :edge_b,
  source_distance_mm: 0.0,
  source_parameter: 0.5
}]

if normalizer.send(:boundary_incidence_valid?, incidences.first, targets)
  raise 'fixture must be invalid after independent nearest rounding'
end

repaired, report = normalizer.send(
  :repair_boundary_incidence_grid_targets,
  incidences,
  [],
  [],
  targets,
  source_mm,
  {},
  {}
)

unless normalizer.send(:boundary_incidence_valid?, incidences.first, repaired)
  raise "repair did not preserve incidence: #{repaired.inspect}"
end
unless report[:boundary_incidence_initial_invalid_count] == 1
  raise "initial invalid count missing: #{report.inspect}"
end
unless report[:boundary_incidence_repaired_source_point_count].positive?
  raise "no target changed: #{report.inspect}"
end
if report[:boundary_incidence_max_repaired_target_displacement_mm] > 0.0015
  raise "repair exceeded adjacent floor/ceil range: #{report.inspect}"
end

puts 'LocalVertexNormalizer boundary-incidence grid target smoke test: OK'
