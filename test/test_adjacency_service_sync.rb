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
          @original_entity_axis = Utils::Geometry.method(:adjacency_axis)
          @original_axis = Utils::Geometry.method(:adjacency_axis_from_snapshots)
        end

        def teardown
          Utils::Geometry.define_singleton_method(:adjacency_snapshot, @original_snapshot)
          Utils::Geometry.define_singleton_method(:adjacency_axis, @original_entity_axis)
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
          assert metrics.key?(:total_duration)
          assert metrics.key?(:adjacency_detailed_computation)
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

        def test_synchronize_for_allows_z_axis_adjacency
          cell_a = fake_cell('A')
          cell_b = fake_cell('B')
          registry = FakeRegistry.new([cell_a, cell_b])
          built = []
          erased = []
          stub_entity_axis(:z)
          service = AdjacencyService.new(
            registry,
            transition_builder: proc { |cell1, cell2| built << [cell1.id, cell2.id] },
            transition_eraser: proc { |pair_key| erased << pair_key; registry.delete_adjacent_pair(pair_key) }
          )

          service.synchronize_for(cell_a)

          assert_equal ['A:B'], registry.adjacent_pair_keys
          assert_equal [['A', 'B']], built
          assert_empty erased
        end

        def test_synchronize_for_axis_policy_is_independent_of_cell_type
          cases = [
            [:general, :general],
            [:general, :transition],
            [:transition, :transition],
            [:connection, :general]
          ]

          cases.each do |type_a, type_b|
            cell_a = fake_cell("A_#{type_a}_#{type_b}", cell_type: type_a)
            cell_b = fake_cell("B_#{type_a}_#{type_b}", cell_type: type_b)
            registry = FakeRegistry.new([cell_a, cell_b], adjacent_pair_keys: ["#{cell_a.id}:#{cell_b.id}"])
            built = []
            erased = []
            stub_entity_axis(:z)
            service = AdjacencyService.new(
              registry,
              transition_builder: proc { |cell1, cell2| built << [cell1.id, cell2.id] },
              transition_eraser: proc { |pair_key| erased << pair_key; registry.delete_adjacent_pair(pair_key) }
            )

            service.synchronize_for(cell_a)

            assert_equal [[cell_a.id, cell_b.id]], built
            assert_empty erased

            built.clear
            stub_entity_axis(nil)
            service.synchronize_for(cell_a)

            assert_empty built
            assert_equal [service.cell_pair_key(cell_a, cell_b)], erased
          end
        end

        def test_synchronize_all_allows_z_axis_adjacency
          cell_a = fake_cell('A', adjacent_to: ['B'])
          cell_b = fake_cell('B', adjacent_to: ['A'])
          registry = FakeRegistry.new([cell_a, cell_b])
          built = []
          stub_snapshot_geometry(axis: :z)
          service = AdjacencyService.new(
            registry,
            transition_builder: proc { |cell1, cell2| built << [cell1.id, cell2.id] },
            transition_eraser: proc { |pair_key| registry.delete_adjacent_pair(pair_key) }
          )

          service.synchronize_all

          assert_equal ['A:B'], registry.adjacent_pair_keys
          assert_equal [['A', 'B']], built
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

          result = service.send(:compute_pair_results, entries, tolerance: Utils::Geometry::ADJACENCY_TOLERANCE)

          assert_equal [[0, 1, :x]], result
          assert_equal [['A', 'B', true]], seen_arguments
        end

        def test_pair_computation_uses_one_serial_chunk_regardless_of_pair_count
          [10, 20_001].each do |pair_count|
            service = build_service
            pairs = Array.new(pair_count, [0, 1]).freeze
            service.define_singleton_method(:candidate_pair_indices) do |_snapshots, _tolerance|
              pairs
            end
            calls = []
            caller_thread = Thread.current
            service.define_singleton_method(:compute_pair_chunk) do |_snapshots, pair_indices, _tolerance|
              calls << [pair_indices.length, Thread.current]
              []
            end

            result = service.send(:compute_pair_results, [{ snapshot: snapshot_for('A') }], tolerance: 0.001)

            assert_empty result
            assert_equal [[pair_count, caller_thread]], calls
            assert_equal pair_count, service.instance_variable_get(:@last_pair_comparison_count)
          end
        end

        def test_parallel_constants_and_helpers_are_removed
          refute AdjacencyService.const_defined?(:MIN_PARALLEL_PAIRS, false)
          refute AdjacencyService.const_defined?(:PAIR_CHUNK_SIZE, false)
          refute AdjacencyService.const_defined?(:MAX_WORKERS, false)
          refute_includes AdjacencyService.private_instance_methods, :compute_pair_results_in_parallel
          refute_includes AdjacencyService.private_instance_methods, :worker_count
        end

        def test_candidate_pairs_skip_redundant_snapshot_bounds_check
          service = build_service
          seen_arguments = []
          Utils::Geometry.define_singleton_method(:adjacency_axis_from_snapshots) do |snapshot1, snapshot2, tolerance:, bounds_checked: false|
            seen_arguments << [snapshot1[:id], snapshot2[:id], tolerance, bounds_checked]
            :x
          end
          entries = [
            { snapshot: snapshot_for('A', bounds: bounds([0, 0, 0], [1, 1, 1])) },
            { snapshot: snapshot_for('B', bounds: bounds([1, 0, 0], [2, 1, 1])) },
            { snapshot: snapshot_for('C', bounds: bounds([10, 10, 10], [11, 11, 11])) }
          ]

          result = service.send(:compute_pair_results, entries, tolerance: 0.001)

          assert_equal [[0, 1, :x]], result
          assert_equal [['A', 'B', 0.001, true]], seen_arguments
          assert_equal 1, service.instance_variable_get(:@last_pair_comparison_count)
        end

        def test_adjacency_and_validation_share_topology_tolerance
          assert_equal Utils::Geometry::TOPOLOGY_TOLERANCE, Utils::Geometry::ADJACENCY_TOLERANCE
          assert_equal Utils::Geometry::TOPOLOGY_TOLERANCE, Utils::Geometry::VALIDATION_TOLERANCE
        end

        private

        def build_service
          AdjacencyService.new(
            FakeRegistry.new([]),
            transition_builder: proc {},
            transition_eraser: proc {}
          )
        end

        def stub_entity_axis(axis)
          Utils::Geometry.define_singleton_method(:adjacency_axis) do |_entity1, _entity2|
            axis
          end
        end

        def stub_snapshot_geometry(seen_arguments: nil, axis: :x)
          Utils::Geometry.define_singleton_method(:adjacency_snapshot) do |entity|
            entity.snapshot
          end
          Utils::Geometry.define_singleton_method(:adjacency_axis_from_snapshots) do |snapshot1, snapshot2, tolerance:, bounds_checked: false|
            seen_arguments << [snapshot1[:id], snapshot2[:id], bounds_checked] if seen_arguments
            snapshot1[:adjacent_to].include?(snapshot2[:id]) ? axis : nil
          end
        end

        def fake_cell(id, adjacent_to: [], cell_type: :general)
          entity = Struct.new(:snapshot).new(snapshot_for(id, adjacent_to: adjacent_to))
          Struct.new(:id, :sketchup_group, :duality_state, :cell_type) do
            def valid?
              true
            end
          end.new(id, entity, fake_state, cell_type)
        end

        def fake_state
          Struct.new(:valid?) do
          end.new(true)
        end

        def snapshot_for(id, adjacent_to: [], bounds: bounds([0.0, 0.0, 0.0], [1.0, 1.0, 1.0]))
          {
            id: id,
            adjacent_to: adjacent_to,
            bounds: bounds,
            faces: []
          }.freeze
        end

        def bounds(minimum, maximum)
          { min: minimum, max: maximum }
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
