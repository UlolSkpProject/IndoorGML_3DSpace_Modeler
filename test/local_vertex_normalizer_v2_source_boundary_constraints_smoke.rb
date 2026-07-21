# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        class ReconstructionError < StandardError; end
        class TopologyChangedError < StandardError; end

        def initialize
          @tolerance_mm = 0.001
        end

        private

        def short_edge_sliver_collapse_plan(_entities, _plan = nil)
          { point_targets: {} }
        end

        def retriangulate_exact_coplanar_patches(
          records,
          forced_source_face_keys: [],
          force_all: false
        )
          forced_source_face_keys
          force_all
          [records, {}]
        end

        def grid_indices(point)
          point
        end

        def canonical_edge_key(first, second)
          [first, second].sort
        end

        def integer_subtract(first, second)
          first.zip(second).map { |a, b| a - b }
        end

        def integer_cross(first, second)
          [
            first[1] * second[2] - first[2] * second[1],
            first[2] * second[0] - first[0] * second[2],
            first[0] * second[1] - first[1] * second[0]
          ]
        end

        def integer_dot(first, second)
          first.zip(second).sum { |a, b| a * b }
        end

        def vector_dot(first, second)
          integer_dot(first, second)
        end

        def vector_length(vector)
          Math.sqrt(vector_dot(vector, vector).to_f)
        end

        def integer_triangle_normal(triangle)
          integer_cross(
            integer_subtract(triangle[1], triangle[0]),
            integer_subtract(triangle[2], triangle[0])
          )
        end

        def integer_zero_vector?(vector)
          vector.all?(&:zero?)
        end

        def integer_point_between?(point, first, second)
          direction = integer_subtract(second, first)
          offset = integer_subtract(point, first)
          return false unless integer_zero_vector?(integer_cross(direction, offset))
          return false if point == first || point == second

          3.times.all? do |axis|
            point[axis].between?(*[first[axis], second[axis]].minmax)
          end
        end

        def integer_points_on_segment_sorted(first, second, candidates)
          direction = integer_subtract(second, first)
          axis = direction.each_index.max_by { |index| direction[index].abs }
          denominator = direction[axis]
          return [first, second] if denominator.zero?

          candidates.select do |point|
            point == first || point == second ||
              integer_point_between?(point, first, second)
          end.sort_by do |point|
            Rational(point[axis] - first[axis], denominator)
          end.uniq
        end

        def grid_triangle_sliver?(points)
          triangle = points.map { |point| grid_indices(point) }
          normal = integer_triangle_normal(triangle)
          area2 = Math.sqrt(integer_dot(normal, normal).to_f)
          longest = 3.times.map do |index|
            edge = integer_subtract(
              triangle[index],
              triangle[(index + 1) % 3]
            )
            Math.sqrt(integer_dot(edge, edge).to_f)
          end.max
          longest.zero? || (area2 / longest) * @tolerance_mm < @tolerance_mm
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/source_face_boundary_constraints_v2'

normalizer = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer.new

# Removing the only triangle that carried M must be detected as a source-Face
# boundary provenance change. The surviving mesh incorrectly exposes A-B.
a = [0, 0, 0]
m = [5, -1, 0]
b = [10, 0, 0]
c = [10, 10, 0]
d = [0, 10, 0]
constraint = {
  source_face_key: 10,
  source_normal: [0, 0, 1],
  loops: [{ outer: true, points: [a, m, b, c, d] }]
}
records = [
  { points: [a, b, c], source_face_key: 10, source_normal: [0, 0, 1] },
  { points: [a, c, d], source_face_key: 10, source_normal: [0, 0, 1] }
]
plan = normalizer.send(
  :source_face_constraint_rebuild_plan,
  records,
  { 10 => constraint },
  [],
  force_all: false
)
unless plan[:reasons][10].include?(:boundary_provenance_changed)
  raise "missing boundary provenance detection: #{plan.inspect}"
end

# A microscopic triangle whose normal is unrelated to its source Face normal
# must be detected as a foreign-plane sliver, independent of any PID/coordinate.
vertical_constraint = {
  source_face_key: 20,
  source_normal: [0, -1, 0],
  loops: [{
    outer: true,
    points: [[0, 0, 0], [0, 0, 10], [10, 0, 10], [10, 0, 0]]
  }]
}
vertical_records = [
  {
    points: [[0, 0, 0], [0, 0, 10], [10, 0, 10]],
    source_face_key: 20,
    source_normal: [0, -1, 0]
  },
  {
    points: [[0, 0, 0], [10, 0, 10], [10, 0, 0]],
    source_face_key: 20,
    source_normal: [0, -1, 0]
  },
  {
    points: [[0, 0, 0], [5, 0, 0], [10, 1, 0]],
    source_face_key: 20,
    source_normal: [0, -1, 0]
  }
]
plan = normalizer.send(
  :source_face_constraint_rebuild_plan,
  vertical_records,
  { 20 => vertical_constraint },
  [],
  force_all: false
)
unless plan[:reasons][20].include?(:foreign_plane_sliver)
  raise "missing foreign-plane sliver detection: #{plan.inspect}"
end

puts 'LocalVertexNormalizer source boundary constraint plan smoke test: OK'
