# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/utils/geometry'
require_relative '../indoor3d/application/adjacency_service/geometry_query'
require_relative '../indoor3d/application/adjacency_service/sync'
require_relative '../indoor3d/application/adjacency_service/snapshot_waypoint_reuse'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AdjacencySnapshotWaypointReuseTest < Minitest::Test
        def setup
          @original_snapshot = Utils::Geometry.method(:adjacency_snapshot)
          @original_axis = Utils::Geometry.method(:adjacency_axis_from_snapshots)
        end

        def teardown
          Utils::Geometry.define_singleton_method(:adjacency_snapshot, @original_snapshot)
          Utils::Geometry.define_singleton_method(:adjacency_axis_from_snapshots, @original_axis)
        end

        def test_synchronize_all_reuses_snapshot_context_with_two_argument_builder
          cell1 = fake_cell('A', snapshot_with_face(normal: [1.0, 0.0, 0.0]))
          cell2 = fake_cell('B', snapshot_with_face(normal: [-1.0, 0.0, 0.0]))
          registry = FakeRegistry.new([cell1, cell2])
          captured = []
          stub_snapshots
          service = AdjacencyService.new(
            registry,
            transition_builder: proc do |first, second|
              captured << [
                first.id,
                second.id,
                AdjacencyService::SnapshotWaypointReuse.current_context
              ]
            end,
            transition_eraser: proc {}
          )

          metrics = service.synchronize_all

          assert_equal 1, captured.length
          assert_equal ['A', 'B'], captured.first.first(2)
          context = captured.first.last
          assert_equal :x, context[:axis]
          assert_equal 1, context[:waypoint_snapshot_candidates].length
          assert_equal 1, metrics[:waypoint_snapshot_pair_analysis_count]
          assert_equal 1, metrics[:waypoint_snapshot_context_hits]
          assert_equal 0, metrics[:waypoint_snapshot_context_fallbacks]
        end

        def test_unsupported_snapshots_keep_legacy_axis_and_live_fallback
          cell1 = fake_cell('A', empty_snapshot('A'))
          cell2 = fake_cell('B', empty_snapshot('B'))
          registry = FakeRegistry.new([cell1, cell2])
          captured_contexts = []
          stub_snapshots
          Utils::Geometry.define_singleton_method(:adjacency_axis_from_snapshots) do |_first, _second, tolerance:|
            tolerance
            :z
          end
          service = AdjacencyService.new(
            registry,
            transition_builder: proc do |_first, _second|
              captured_contexts << AdjacencyService::SnapshotWaypointReuse.current_context
            end,
            transition_eraser: proc {}
          )

          metrics = service.synchronize_all

          assert_equal [nil], captured_contexts
          assert_equal 1, metrics[:waypoint_snapshot_pair_analysis_count]
          assert_equal 0, metrics[:waypoint_snapshot_context_hits]
          assert_equal 1, metrics[:waypoint_snapshot_context_fallbacks]
        end

        def test_pair_result_contract_remains_three_values
          cell1 = fake_cell('A', snapshot_with_face(normal: [1.0, 0.0, 0.0]))
          cell2 = fake_cell('B', snapshot_with_face(normal: [-1.0, 0.0, 0.0]))
          service = AdjacencyService.new(
            FakeRegistry.new([]),
            transition_builder: proc {},
            transition_eraser: proc {}
          )
          entries = [
            { cell_space: cell1, snapshot: cell1.sketchup_group.snapshot },
            { cell_space: cell2, snapshot: cell2.sketchup_group.snapshot }
          ]

          result = service.send(
            :compute_pair_results,
            entries,
            tolerance: Utils::Geometry::ADJACENCY_TOLERANCE
          )

          assert_equal [[0, 1, :x]], result
        end

        private

        def stub_snapshots
          Utils::Geometry.define_singleton_method(:adjacency_snapshot) do |entity|
            entity.snapshot
          end
        end

        def fake_cell(id, snapshot)
          entity = Struct.new(:snapshot).new(snapshot)
          state = Struct.new(:valid?).new(true)
          Struct.new(:id, :sketchup_group, :duality_state) do
            def valid?
              true
            end
          end.new(id, entity, state)
        end

        def empty_snapshot(id)
          {
            id: id,
            bounds: { min: [0.0, 0.0, 0.0], max: [1.0, 1.0, 1.0] },
            faces: []
          }.freeze
        end

        def snapshot_with_face(normal:)
          points = [
            [1.0, 0.0, 0.0],
            [1.0, 1.0, 0.0],
            [1.0, 1.0, 1.0],
            [1.0, 0.0, 1.0]
          ]
          triangles = [
            [points[0], points[1], points[2]],
            [points[0], points[2], points[3]]
          ]
          {
            bounds: { min: [1.0, 0.0, 0.0], max: [1.0, 1.0, 1.0] },
            faces: [
              {
                points: points,
                normal: normal,
                triangles: triangles
              }
            ]
          }.freeze
        end

        class FakeRegistry
          attr_reader :cell_spaces

          def initialize(cell_spaces)
            @cell_spaces = cell_spaces
            @adjacent_pairs = {}
          end

          def set_adjacent_pair(pair_key, _cell1, _cell2)
            @adjacent_pairs[pair_key] = true
          end

          def adjacent_pair_keys
            @adjacent_pairs.keys
          end

          def transition_pair_keys
            []
          end
        end
      end
    end
  end
end
