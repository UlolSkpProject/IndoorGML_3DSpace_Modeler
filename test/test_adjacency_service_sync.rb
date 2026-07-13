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
          assert_equal [['A', 'B']], seen_arguments
        end

        def test_adjacency_and_validation_share_topology_tolerance
          assert_equal Utils::Geometry::TOPOLOGY_TOLERANCE, Utils::Geometry::ADJACENCY_TOLERANCE
          assert_equal Utils::Geometry::TOPOLOGY_TOLERANCE, Utils::Geometry::VALIDATION_TOLERANCE
        end

        def test_candidate_pair_indices_matches_brute_force_for_edge_cases
          tolerance = 0.1
          cases = {
            empty: [[], []],
            single: [[bounds_snapshot([0, 0, 0], [1, 1, 1])], []],
            same_min_z_with_different_max_z: [
              [
                bounds_snapshot([0, 0, 0], [1, 1, 1]),
                bounds_snapshot([0, 0, 0], [1, 1, 3]),
                bounds_snapshot([0, 0, 1.05], [1, 1, 2])
              ],
              [[0, 1], [0, 2], [1, 2]]
            ],
            separated_floors: [
              [bounds_snapshot([0, 0, 0], [1, 1, 1]), bounds_snapshot([0, 0, 1.1001], [1, 1, 2])],
              []
            ],
            overlapping_z_separated_x: [
              [bounds_snapshot([0, 0, 0], [1, 1, 2]), bounds_snapshot([1.1001, 0, 1], [2, 1, 3])],
              []
            ],
            overlapping_z_separated_y: [
              [bounds_snapshot([0, 0, 0], [1, 1, 2]), bounds_snapshot([0, 1.1001, 1], [1, 2, 3])],
              []
            ],
            exactly_touching: [
              [bounds_snapshot([0, 0, 0], [1, 1, 1]), bounds_snapshot([1, 1, 1], [2, 2, 2])],
              [[0, 1]]
            ],
            touching_within_tolerance: [
              [bounds_snapshot([0, 0, 0], [1, 1, 1]), bounds_snapshot([1.1, 1.1, 1.1], [2, 2, 2])],
              [[0, 1]]
            ],
            separated_beyond_tolerance: [
              [bounds_snapshot([0, 0, 0], [1, 1, 1]), bounds_snapshot([1.1001, 1.1001, 1.1001], [2, 2, 2])],
              []
            ],
            negative_z_coordinates: [
              [bounds_snapshot([0, 0, -5], [1, 1, -2]), bounds_snapshot([0, 0, -2.05], [1, 1, 0])],
              [[0, 1]]
            ],
            duplicate_bounds: [
              Array.new(3) { bounds_snapshot([-1, -1, -1], [1, 1, 1]) },
              [[0, 1], [0, 2], [1, 2]]
            ]
          }

          cases.each do |name, (snapshots, expected)|
            brute_force_pairs = brute_force_candidate_pair_indices(snapshots, tolerance)
            sweep_pairs = candidate_pair_indices(snapshots, tolerance)

            assert_equal expected, brute_force_pairs, "brute-force fixture mismatch for #{name}"
            assert_equal brute_force_pairs.sort, sweep_pairs.sort, "pair set mismatch for #{name}"
            assert sweep_pairs.all? { |index1, index2| index1 < index2 }, "unordered pair for #{name}"
            assert_predicate sweep_pairs, :frozen?, "result must be frozen for #{name}"
          end
        end

        def test_candidate_pair_indices_matches_brute_force_for_generated_bounds
          tolerance = 0.25
          random = Random.new(12_345)

          40.times do |iteration|
            snapshots = Array.new(random.rand(0..40)) do
              minimum = Array.new(3) { random.rand(-20.0..20.0) }
              maximum = minimum.map { |coordinate| coordinate + random.rand(0.0..5.0) }
              bounds_snapshot(minimum, maximum)
            end

            brute_force_pairs = brute_force_candidate_pair_indices(snapshots, tolerance)
            sweep_pairs = candidate_pair_indices(snapshots, tolerance)

            assert_equal brute_force_pairs.sort, sweep_pairs.sort, "pair set mismatch at iteration #{iteration}"
            assert sweep_pairs.all? { |index1, index2| index1 < index2 }, "unordered pair at iteration #{iteration}"
            assert_predicate sweep_pairs, :frozen?
          end
        end

        private

        def candidate_pair_indices(snapshots, tolerance)
          service = AdjacencyService.new(
            FakeRegistry.new([]),
            transition_builder: proc {},
            transition_eraser: proc {}
          )
          service.send(:candidate_pair_indices, snapshots, tolerance)
        end

        def brute_force_candidate_pair_indices(snapshots, tolerance)
          pairs = []
          snapshots.each_index do |index1|
            ((index1 + 1)...snapshots.length).each do |index2|
              bounds1 = snapshots[index1][:bounds]
              bounds2 = snapshots[index2][:bounds]
              matches = 3.times.all? do |axis|
                [bounds1[:min][axis], bounds2[:min][axis]].max <=
                  [bounds1[:max][axis], bounds2[:max][axis]].min + tolerance
              end
              pairs << [index1, index2] if matches
            end
          end
          pairs.freeze
        end

        def bounds_snapshot(minimum, maximum)
          { bounds: { min: minimum, max: maximum } }.freeze
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
          Utils::Geometry.define_singleton_method(:adjacency_axis_from_snapshots) do |snapshot1, snapshot2, tolerance:|
            seen_arguments << [snapshot1[:id], snapshot2[:id]] if seen_arguments
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
