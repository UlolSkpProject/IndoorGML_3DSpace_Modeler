# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        STRICT_COPLANAR_TOLERANCE_MM = 0.00001 unless const_defined?(:STRICT_COPLANAR_TOLERANCE_MM, false)
        STRICT_COPLANAR_ANGLE_TOLERANCE_DEG = 0.001 unless const_defined?(:STRICT_COPLANAR_ANGLE_TOLERANCE_DEG, false)

        class ReconstructionError < StandardError; end unless const_defined?(:ReconstructionError, false)
        class TopologyChangedError < StandardError; end unless const_defined?(:TopologyChangedError, false)

        def initialize
          @tolerance_mm = 0.001
        end

        private

        def repair_degenerate_source_triangles(records, coordinate_space: :grid)
          raise ReconstructionError, 'unresolved source zero-area triangle' if coordinate_space == :source
          [records, { repaired_triangles: 0, replaced_pairs: 0 }]
        end

        def normalize_triangle_records_allowing_collisions(records, _plan = nil, duplicate_diagnostics: nil)
          duplicate_diagnostics
          [records, { forced_source_face_keys: [] }]
        end

        def degenerate_triangle_record?(record, coordinate_space: :grid)
          triangle = record[:points]
          coordinate_space
          triangle.uniq.length != 3 || integer_zero_vector?(integer_triangle_normal(triangle))
        end

        def source_face_keys_with_adjacent_triangles(records, indices, coordinate_space:)
          coordinate_space
          indices.map { |index| records[index][:source_face_key] }.compact.uniq
        end

        def triangle_signature_for_space(points, _space)
          points.sort
        end

        def grid_indices(point)
          point
        end

        def canonical_edge_key(first, second)
          [first, second].sort
        end

        def integer_subtract(first, second)
          [first[0] - second[0], first[1] - second[1], first[2] - second[2]]
        end

        def integer_cross(first, second)
          [
            (first[1] * second[2]) - (first[2] * second[1]),
            (first[2] * second[0]) - (first[0] * second[2]),
            (first[0] * second[1]) - (first[1] * second[0])
          ]
        end

        def integer_dot(first, second)
          first.zip(second).sum { |a, b| a * b }
        end

        def vector_dot(first, second)
          first.zip(second).sum { |a, b| a * b }
        end

        def vector_length(vector)
          Math.sqrt(vector_dot(vector, vector))
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

        def integer_point_between?(point, start_point, end_point)
          direction = integer_subtract(end_point, start_point)
          offset = integer_subtract(point, start_point)
          return false unless integer_zero_vector?(integer_cross(direction, offset))
          return false if point == start_point || point == end_point

          3.times.all? do |axis|
            point[axis] >= [start_point[axis], end_point[axis]].min &&
              point[axis] <= [start_point[axis], end_point[axis]].max
          end
        end

        def exact_integer_plane_key(triangle)
          normal = integer_triangle_normal(triangle)
          divisor = normal.map(&:abs).reject(&:zero?).reduce { |gcd, value| gcd.gcd(value) }
          primitive = normal.map { |value| value / divisor }
          primitive = primitive.map(&:-@) if primitive.find { |value| !value.zero? }.negative?
          primitive + [integer_dot(primitive, triangle[0])]
        end

        def exact_boundary_loops(boundary_edges)
          adjacency = Hash.new { |hash, key| hash[key] = [] }
          boundary_edges.each do |first, second|
            adjacency[first] << second
            adjacency[second] << first
          end
          unused = boundary_edges.to_h { |edge| [canonical_edge_key(*edge), true] }
          loops = []
          until unused.empty?
            start_point, current = unused.keys.first
            previous = start_point
            loop_points = [start_point]
            unused.delete(canonical_edge_key(start_point, current))
            until current == start_point
              loop_points << current
              following = adjacency[current].find do |candidate|
                candidate != previous && unused[canonical_edge_key(current, candidate)]
              end
              following ||= adjacency[current].find do |candidate|
                unused[canonical_edge_key(current, candidate)]
              end
              raise 'open loop' unless following
              unused.delete(canonical_edge_key(current, following))
              previous, current = current, following
            end
            loops << loop_points
          end
          loops
        end

        def simplify_exact_loop(loop)
          loop
        end

        def canonical_exact_loop(loop)
          candidates = []
          [loop, loop.reverse].each do |sequence|
            sequence.each_index do |index|
              candidates << sequence[index..] + sequence[0...index]
            end
          end
          candidates.min { |first, second| first <=> second }
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/runtime_regression_fixes_v2'

klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
normalizer = klass.new

degenerate = { points: [[0, 0, 0], [1, 0, 0], [2, 0, 0]], source_face_key: 10 }
valid = { points: [[0, 0, 0], [2, 0, 0], [0, 2, 0]], source_face_key: 10 }
records, report = normalizer.send(
  :repair_degenerate_source_triangles,
  [degenerate, valid],
  coordinate_space: :source
)
raise 'source fallback did not remove zero-area record' unless records.length == 1
raise 'source fallback did not mark forced patch' unless records.first[:force_retriangulation]
raise 'source fallback report missing face key' unless report[:forced_source_face_keys] == [10]

normalized, cleanup = normalizer.send(
  :normalize_triangle_records_allowing_collisions,
  records
)
raise 'force marker was not propagated' unless cleanup[:forced_source_face_keys] == [10]
raise 'normalized records changed unexpectedly' unless normalized == records

missing_plane_triangle = {
  points: [
    [-1_435_618, -195_277, -4_750_000],
    [-599_449, -195_083, -4_403_846],
    [-319_449, -195_018, -4_519_231]
  ]
}
added_plane_triangle = {
  points: [
    [-1_435_618, -195_277, -4_750_000],
    [-879_449, -195_148, -4_288_462],
    [-319_449, -195_018, -4_519_231]
  ]
}
first_plane = normalizer.send(:surface_triangle_plane, missing_plane_triangle)
second_plane = normalizer.send(:surface_triangle_plane, added_plane_triangle)
unless normalizer.send(:surface_planes_compatible?, first_plane, second_plane)
  raise 'strict tolerance plane clustering rejected log-equivalent planes'
end

square_ac = [
  { points: [[0, 0, 0], [10, 0, 0], [10, 10, 0]] },
  { points: [[0, 0, 0], [10, 10, 0], [0, 10, 0]] }
]
square_bd = [
  { points: [[0, 0, 0], [10, 0, 0], [0, 10, 0]] },
  { points: [[10, 0, 0], [10, 10, 0], [0, 10, 0]] }
]
first_descriptor = normalizer.send(:normalized_surface_descriptor, square_ac)
second_descriptor = normalizer.send(:normalized_surface_descriptor, square_bd)
raise 'surface equivalence depends on diagonal' unless first_descriptor == second_descriptor

# PID 2252884 regression: remove_coplanar_shared_edges merges three triangles
# into one five-vertex Face. SketchUp then flips the internal P-B diagonal to
# A-D and emits a 0.14 mm^2 sliver triangle A-D-B. The sliver must inherit the
# stable plane of the same Face instead of becoming an independent plane patch.
q = [-1_159_449, -195_213, -4_173_077]
p_point = [-1_435_618, -195_277, -4_750_000]
a = [-879_449, -195_148, -4_288_462]
b = [-599_449, -195_083, -4_403_846]
d = [-319_449, -195_018, -4_519_231]

expected_diagonal = [
  { points: [q, p_point, a], source_face_key: 101 },
  { points: [p_point, a, b], source_face_key: 102 },
  { points: [p_point, b, d], source_face_key: 103 }
]
actual_flipped_diagonal = [
  { points: [q, p_point, a], source_face_key: 201 },
  { points: [p_point, a, d], source_face_key: 201 },
  { points: [a, d, b], source_face_key: 201 }
]

sliver_plane = normalizer.send(
  :surface_triangle_plane,
  actual_flipped_diagonal.last
)
stable_plane = normalizer.send(
  :surface_triangle_plane,
  actual_flipped_diagonal.first
)
if normalizer.send(:surface_planes_compatible?, stable_plane, sliver_plane)
  raise 'regression fixture no longer exposes an unstable sliver plane'
end

expected_descriptor = normalizer.send(
  :normalized_surface_descriptor,
  expected_diagonal
)
actual_descriptor = normalizer.send(
  :normalized_surface_descriptor,
  actual_flipped_diagonal
)
unless expected_descriptor == actual_descriptor
  raise 'same Face with a flipped sliver diagonal changed surface descriptor'
end

unless klass::STRICT_COPLANAR_TOLERANCE_MM == 0.00001
  raise 'strict coplanar tolerance was not raised to 0.00001 mm'
end

puts 'LocalVertexNormalizer v2 runtime regression smoke test: OK'
