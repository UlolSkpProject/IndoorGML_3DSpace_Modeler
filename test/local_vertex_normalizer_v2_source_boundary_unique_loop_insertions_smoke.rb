# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        def source_boundary_common_refinement_splits(_edges)
          [@split_fixture, @relation_fixture]
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/source_face_boundary_unique_loop_insertions_v2'

normalizer =
  ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer.new

point = lambda do |key|
  {
    source_key: key,
    point: key,
    point_mm: [0.0, 0.0, 0.0],
    face_keys: {}
  }
end

a = point.call(:a)
b = point.call(:b)
c = point.call(:c)
d = point.call(:d)
p = point.call(:p)

edges = [
  {
    edge_index: 0,
    face_key: 30,
    loop_index: 0,
    first: a,
    second: b
  },
  {
    edge_index: 1,
    face_key: 30,
    loop_index: 0,
    first: b,
    second: c
  },
  {
    edge_index: 2,
    face_key: 30,
    loop_index: 0,
    first: c,
    second: d
  },
  {
    edge_index: 3,
    face_key: 30,
    loop_index: 0,
    first: d,
    second: a
  }
]

existing_vertex_entry = {
  point_entry: c,
  source_parameter: 0.5,
  source_distance_mm: 0.00001,
  overlap_length_mm: 5.0
}
preferred_p_entry = {
  point_entry: p,
  source_parameter: 0.4,
  source_distance_mm: 0.00001,
  overlap_length_mm: 8.0
}
competing_p_entry = {
  point_entry: p,
  source_parameter: 0.6,
  source_distance_mm: 0.00002,
  overlap_length_mm: 20.0
}

normalizer.instance_variable_set(
  :@split_fixture,
  {
    0 => [existing_vertex_entry, preferred_p_entry],
    2 => [competing_p_entry]
  }
)
normalizer.instance_variable_set(
  :@relation_fixture,
  [
    { host_edge_index: 0, inserted_source_key: :c },
    { host_edge_index: 0, inserted_source_key: :p },
    { host_edge_index: 2, inserted_source_key: :p }
  ]
)

splits, relations = normalizer.send(
  :source_boundary_common_refinement_splits,
  edges
)

unless splits.keys == [0] &&
       splits.fetch(0).length == 1 &&
       splits.fetch(0).first[:point_entry][:source_key] == :p
  raise "unique loop insertion selection failed: #{splits.inspect}"
end

unless relations == [{ host_edge_index: 0, inserted_source_key: :p }]
  raise "filtered relations do not match selected insertion: #{relations.inspect}"
end

report = normalizer.instance_variable_get(
  :@source_boundary_unique_loop_insertion_report
)
unless report == {
  suppressed_existing_loop_vertex_count: 1,
  suppressed_competing_edge_count: 1,
  selected_insertion_count: 1
}
  raise "unexpected unique insertion report: #{report.inspect}"
end

puts 'LocalVertexNormalizer source boundary unique-loop insertion smoke test: OK'
