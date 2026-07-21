# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        class Error < StandardError; end
        class ReconstructionError < Error; end
        class TopologyChangedError < Error; end

        MM_PER_INCH = 25.4
        GRID_EPSILON_MM = 0.000001

        def initialize
          @tolerance_mm = 0.001
        end

        private

        def axis_plane_normalization_plan(_entities)
          {}
        end

        def normalized_target(point, _plan = nil)
          point
        end

        def point_from_grid_indices(indices)
          indices
        end

        def integer_polygon_area2(polygon)
          polygon.each_index.sum do |index|
            following = (index + 1) % polygon.length
            (polygon[index][0] * polygon[following][1]) -
              (polygon[following][0] * polygon[index][1])
          end
        end

        def integer_orientation_2d(first, second, third)
          ((second[0] - first[0]) * (third[1] - first[1])) -
            ((second[1] - first[1]) * (third[0] - first[0]))
        end

        def integer_point_on_segment_2d?(point, first, second)
          return false unless integer_orientation_2d(first, second, point).zero?

          point[0].between?(*[first[0], second[0]].minmax) &&
            point[1].between?(*[first[1], second[1]].minmax)
        end

        def integer_segments_intersect_2d?(a1, a2, b1, b2)
          o1 = integer_orientation_2d(a1, a2, b1)
          o2 = integer_orientation_2d(a1, a2, b2)
          o3 = integer_orientation_2d(b1, b2, a1)
          o4 = integer_orientation_2d(b1, b2, a2)

          return true if o1.zero? && integer_point_on_segment_2d?(b1, a1, a2)
          return true if o2.zero? && integer_point_on_segment_2d?(b2, a1, a2)
          return true if o3.zero? && integer_point_on_segment_2d?(a1, b1, b2)
          return true if o4.zero? && integer_point_on_segment_2d?(a2, b1, b2)

          (o1.positive? != o2.positive?) &&
            (o3.positive? != o4.positive?)
        end

        def integer_point_in_polygon_2d?(point, polygon)
          inside = false
          following = polygon.length - 1
          polygon.each_index do |index|
            current = polygon[index]
            previous = polygon[following]
            return true if integer_point_on_segment_2d?(point, previous, current)

            crosses = (current[1] > point[1]) != (previous[1] > point[1])
            if crosses
              numerator =
                (previous[0] - current[0]) * (point[1] - current[1])
              denominator = previous[1] - current[1]
              intersection_x = Rational(numerator, denominator) + current[0]
              inside = !inside if point[0] < intersection_x
            end
            following = index
          end
          inside
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/topology_preserving_grid_targets_v2'

klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
normalizer = klass.new

# Generic simple five-vertex polygon whose independent nearest-grid rounding
# makes two non-adjacent edges cross. No PID or model-specific branch is used.
source_mm = [
  [3522.125596716979, -19017.182949551767, 4099.016717469484],
  [3207.9793236015876, -18994.0071198552, 4099.016717469484],
  [-3354.676337942924, -18108.766664434526, 4099.016717469484],
  [-3384.1059629046717, -18507.682566278167, 4099.016717469484],
  [-3698.2521285561043, -18484.50674735483, 4099.016717469484]
]
keys = %w[a b c d e]
source_mm_by_key = keys.zip(source_mm).to_h
initial_targets = keys.zip(
  source_mm.map do |point|
    point.map { |coordinate| (coordinate / 0.001).round }
  end
).to_h
face_records = [{
  face_key: :generic_near_touching_face,
  drop_axis: 2,
  loops: [{
    outer: true,
    source_keys: keys,
    source_orientation: 1
  }]
}]

initial_analysis = normalizer.send(
  :topology_face_embedding_analysis,
  face_records.first,
  initial_targets
)
raise 'fixture must fail under independent rounding' if initial_analysis[:valid]

axis_constraints = keys.to_h do |key|
  [key, { 2 => initial_targets[key][2] }]
end
repaired, report = normalizer.send(
  :repair_topology_grid_targets,
  face_records,
  initial_targets,
  source_mm_by_key,
  axis_constraints
)

final_analysis = normalizer.send(
  :topology_face_embedding_analysis,
  face_records.first,
  repaired
)
raise "repaired target remains invalid: #{final_analysis.inspect}" unless
  final_analysis[:valid]
raise "expected one repaired Face: #{report.inspect}" unless
  report[:repaired_face_count] == 1
raise "expected at least one target override: #{report.inspect}" unless
  report[:repaired_source_point_count].positive?
raise "repair moved farther than adjacent floor/ceil target: #{report.inspect}" if
  report[:max_repaired_target_displacement_mm] > 0.0015

# Every hard Z-axis constraint must remain exact.
keys.each do |key|
  unless repaired[key][2] == initial_targets[key][2]
    raise "hard axis constraint changed for #{key}: #{repaired[key].inspect}"
  end
end

puts 'LocalVertexNormalizer topology-preserving grid target smoke test: OK'
