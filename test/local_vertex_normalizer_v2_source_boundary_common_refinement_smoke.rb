# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        STRICT_COPLANAR_TOLERANCE_MM = 0.0001
        class ReconstructionError < StandardError; end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/source_face_boundary_common_refinement_v2'

klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
normalizer = klass.new

point = lambda do |key, xyz, face_key|
  {
    source_key: key,
    point: key,
    point_mm: xyz,
    face_keys: { face_key => true }
  }
end

a = point.call(:a, [0.0, 0.0, 0.0], 1)
p = point.call(:p, [5.0, 0.00005, 0.0], 2)
b = point.call(:b, [10.0, 0.0, 0.0], 1)
q = point.call(:q, [5.0, 0.00004, 0.0], 3)
r = point.call(:r, [5.0, 1.0, 0.0], 3)

# Face 1 has the long boundary A-B. Face 2 contributes overlapping boundaries
# A-P and P-B. Face 3 owns an isolated nearby vertex Q, but its Edge Q-R is not
# collinear with A-B and therefore must not influence Face 1's subdivision.
edges = [
  { edge_index: 0, face_key: 1, loop_index: 0, first: a, second: b },
  { edge_index: 1, face_key: 2, loop_index: 0, first: a, second: p },
  { edge_index: 2, face_key: 2, loop_index: 0, first: p, second: b },
  { edge_index: 3, face_key: 3, loop_index: 0, first: q, second: r }
]

splits, relations = normalizer.send(
  :source_boundary_common_refinement_splits,
  edges
)
inserted = Array(splits[0]).map do |entry|
  entry[:point_entry][:source_key]
end
unless inserted == [:p]
  raise "expected only P on A-B, got #{inserted.inspect}"
end
if inserted.include?(:q)
  raise 'isolated near vertex Q was incorrectly inserted'
end
unless relations.length == 1
  raise "expected one host insertion relation, got #{relations.inspect}"
end

# Partial overlap with no shared source keys must refine both source segments
# using the union of their endpoints: C-D gets E, and E-F gets D.
c = point.call(:c, [0.0, 5.0, 0.0], 10)
d = point.call(:d, [10.0, 5.0, 0.0], 10)
e = point.call(:e, [5.0, 5.00005, 0.0], 11)
f = point.call(:f, [15.0, 5.00005, 0.0], 11)
partial_edges = [
  { edge_index: 0, face_key: 10, loop_index: 0, first: c, second: d },
  { edge_index: 1, face_key: 11, loop_index: 0, first: e, second: f }
]
partial_splits, = normalizer.send(
  :source_boundary_common_refinement_splits,
  partial_edges
)
first_insertions = Array(partial_splits[0]).map do |entry|
  entry[:point_entry][:source_key]
end
second_insertions = Array(partial_splits[1]).map do |entry|
  entry[:point_entry][:source_key]
end
raise 'E must split C-D' unless first_insertions == [:e]
raise 'D must split E-F' unless second_insertions == [:d]

puts 'LocalVertexNormalizer source boundary common refinement smoke test: OK'
