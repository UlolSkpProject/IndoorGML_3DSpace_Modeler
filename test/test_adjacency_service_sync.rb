# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/utils/geometry'
require_relative '../indoor3d/application/adjacency_service/geometry_query'
require_relative '../indoor3d/application/adjacency_service/sync'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AdjacencyServiceSyncTest < Minitest::Test
        def setup
          @original_snapshot = Utils::Geometry.method(:adjacency_snapshot)
          @original_axis = Utils::Geometry.method(:adjacency_axis_from_snapshots)
        end

        def teardown
          Utils::Geometry.define_singleton_method(:adjacency_snapshot, @original_snapshot)
          Utils::Geometry.define_singleton_method(:adjacency_axis_from_snapshots, @original_axis)
        end

        def test_synchronize_all_applies_new_pairs_and_erases_stale_pairs_once
          cell_a = fake_cell('A', adjacent_to: ['B'])
          cell_b = fake_cell('B', adjacent_to: ['A'])
          cell_c = fake_cell('C')
          registry = FakeRegistry.new([cell_a, cell_b, cell_c], adjacent_pair_keys: ['A:C'])
          built = []
          erased = []
          stub_snapshot_geometry
          service = AdjacencyService.new(
            registry,
            transition_builder: proc { |cell1, cell2| built << [cell1.id, cell2.id] },
            transition_eraser: proc { |pair_key| erased << pair_key; registry.delete_adjacent_pair(pair_key) }
          )

          metrics = service.synchronize_all

          assert_equal ['A:B'], registry.adjacent_pair_keys
          assert_equal [['A', 'B']], built
          assert_equal ['A:C'], erased
          assert_equal 3, metrics[:pair_comparison_count]
        end

        def test_synchronize_all_can_use_runtime_only_callbacks
          cell_a = fake_cell('A', adjacent_to: ['B'])
          cell_b = fake_cell('B', adjacent_to: ['A'])
          registry = FakeRegistry.new([cell_a, cell_b], adjacent_pair_keys: ['A:C'])
          default_calls = []
          runtime_calls = []
          erased = []
          stub_snapshot_geometry
          service = AdjacencyService.new(
            registry,
            transition_builder: proc { |_cell1, _cell2| default_calls << :default_builder },
            transition_eraser: proc { |_pair_key| default_calls << :default_eraser }
          )

          service.synchronize_all(
            transition_builder: proc { |cell1, cell2| runtime_calls << [cell1.id, cell2.id] },
            transition_eraser: proc { |pair_key| erased << pair_key; registry.delete_adjacent_pair(pair_key) }
          )

          assert_empty default_calls
          assert_equal [['A', 'B']], runtime_calls
          assert_equal ['A:C'], erased
          assert_equal ['A:B'], registry.adjacent_pair_keys
        end

        def test_pair_computation_uses_snapshot_values
          service = AdjacencyService.new(
            FakeRegistry.new([]),
            transition_builder: proc {},
            transition_eraser: proc {}
          )
          seen_arguments = []
          stub_snapshot_geometry(seen_arguments: seen_arguments)
          entries = [
            { cell_space: Object.new, snapshot: snapshot_for('A', adjacent_to: ['B']) },
            { cell_space: Object.new, snapshot: snapshot_for('B', adjacent_to: ['A']) }
          ]

          result = service.send(:compute_pair_results, entries, tolerance: 0.001)

          assert_equal [[0, 1, :x]], result
          assert_equal [['A', 'B']], seen_arguments
        end

        private

        def stub_snapshot_geometry(seen_arguments: nil)
          Utils::Geometry.define_singleton_method(:adjacency_snapshot) do |entity|
            entity.snapshot
          end
          Utils::Geometry.define_singleton_method(:adjacency_axis_from_snapshots) do |snapshot1, snapshot2, tolerance:|
            seen_arguments << [snapshot1[:id], snapshot2[:id]] if seen_arguments
            snapshot1[:adjacent_to].include?(snapshot2[:id]) ? :x : nil
          end
        end

        def fake_cell(id, adjacent_to: [])
          entity = Struct.new(:snapshot).new(snapshot_for(id, adjacent_to: adjacent_to))
          Struct.new(:id, :sketchup_group, :duality_state) do
            def valid?
              true
            end
          end.new(id, entity, fake_state)
        end

        def fake_state
          Struct.new(:valid?) do
          end.new(true)
        end

        def snapshot_for(id, adjacent_to: [])
          {
            id: id,
            adjacent_to: adjacent_to,
            bounds: { min: [0.0, 0.0, 0.0], max: [1.0, 1.0, 1.0] },
            faces: []
          }.freeze
        end

        class FakeRegistry
          attr_reader :cell_spaces

          def initialize(cell_spaces, adjacent_pair_keys: [], transition_pair_keys: [])
            @cell_spaces = cell_spaces
            @adjacent_pairs = adjacent_pair_keys.each_with_object({}) { |key, pairs| pairs[key] = true }
            @transition_pair_keys = transition_pair_keys
          end

          def set_adjacent_pair(pair_key, _cell1, _cell2)
            @adjacent_pairs[pair_key] = true
          end

          def adjacent_pair_keys
            @adjacent_pairs.keys
          end

          def delete_adjacent_pair(pair_key)
            @adjacent_pairs.delete(pair_key)
          end

          def transition_pair_keys
            @transition_pair_keys
          end
        end
      end
    end
  end
end
