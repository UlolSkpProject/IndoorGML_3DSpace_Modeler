# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        def initialize
          @inventory_fixture = nil
          @split_fixture = nil
        end

        private

        def topology_grid_source_inventory(_entities, _axis_plane_plan)
          [
            [{
              face_key: 30,
              drop_axis: 2,
              loops: [{
                outer: true,
                source_keys: %i[a b c d],
                source_orientation: 1
              }]
            }],
            {
              a: [0.0, 0.0, 0.0],
              b: [10.0, 0.0, 0.0],
              c: [10.0, 10.0, 0.0],
              d: [0.0, 10.0, 0.0]
            },
            {
              a: [0, 0, 0],
              b: [10, 0, 0],
              c: [10, 10, 0],
              d: [0, 10, 0]
            }
          ]
        end

        def capture_normalized_source_face_constraints(*)
          :captured
        end

        def source_boundary_common_refinement_inventory(_entities)
          @inventory_fixture
        end

        def source_boundary_common_refinement_splits(_edges)
          [@split_fixture, []]
        end

        def normalized_target_before_topology_grid_v2(point, _plan)
          point
        end

        def grid_indices(point)
          point
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/source_face_boundary_common_refinement_topology_v2'

klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
normalizer = klass.new

point = lambda do |key, coordinates|
  {
    source_key: key,
    point: coordinates,
    point_mm: coordinates.map(&:to_f),
    face_keys: {}
  }
end

a = point.call(:a, [0, 0, 0])
b = point.call(:b, [10, 0, 0])
c = point.call(:c, [10, 10, 0])
d = point.call(:d, [0, 10, 0])
p = point.call(:p, [5, -1, 0])

edges = [
  { edge_index: 0, first: a, second: b },
  { edge_index: 1, first: b, second: c },
  { edge_index: 2, first: c, second: d },
  { edge_index: 3, first: d, second: a }
]
inventory = {
  edges: edges,
  faces: [{
    face_key: 30,
    loops: [{ edge_indices: [0, 1, 2, 3] }]
  }]
}
splits = {
  0 => [{
    point_entry: p,
    source_parameter: 0.5,
    source_distance_mm: 0.0
  }]
}

normalizer.instance_variable_set(:@inventory_fixture, inventory)
normalizer.instance_variable_set(:@split_fixture, splits)

entities = Object.new
records, source_mm, targets = normalizer.send(
  :topology_grid_source_inventory,
  entities,
  {}
)

keys = records.fetch(0).fetch(:loops).fetch(0).fetch(:source_keys)
unless keys == %i[a p b c d]
  raise "refined loop was not visible to target planning: #{keys.inspect}"
end
unless source_mm[:p] == [5.0, -1.0, 0.0]
  raise "inserted source point missing from source inventory: #{source_mm.inspect}"
end
unless targets[:p] == [5, -1, 0]
  raise "inserted source point missing from target inventory: #{targets.inspect}"
end

normalizer.instance_variable_set(
  :@source_boundary_common_refinement_topology_cache,
  { entities_object_id: entities.object_id }
)
result = normalizer.send(
  :capture_normalized_source_face_constraints,
  entities,
  {},
  {}
)
raise "capture wrapper changed result: #{result.inspect}" unless result == :captured
unless normalizer.instance_variable_get(
  :@source_boundary_common_refinement_topology_cache
).nil?
  raise 'topology refinement cache was not cleared after capture'
end

puts 'LocalVertexNormalizer boundary common-refinement topology bridge smoke test: OK'
