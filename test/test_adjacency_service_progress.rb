# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/utils/geometry'
require_relative '../indoor3d/application/adjacency_service/geometry_query'
require_relative '../indoor3d/application/adjacency_service/sync'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AdjacencyServiceProgressTest < Minitest::Test
        def setup
          @original_snapshot = Utils::Geometry.method(:adjacency_snapshot)
          @original_axis = Utils::Geometry.method(:adjacency_axis_from_snapshots)
          Utils::Geometry.define_singleton_method(:adjacency_snapshot) { |entity| entity.snapshot }
          Utils::Geometry.define_singleton_method(:adjacency_axis_from_snapshots) do |snapshot1, snapshot2, tolerance:|
            snapshot1[:adjacent_to].include?(snapshot2[:id]) ? :x : nil
          end
        end

        def teardown
          Utils::Geometry.define_singleton_method(:adjacency_snapshot, @original_snapshot)
          Utils::Geometry.define_singleton_method(:adjacency_axis_from_snapshots, @original_axis)
        end

        def test_synchronize_all_reports_snapshot_candidate_detail_and_apply_stages
          cells = [
            fake_cell('A', adjacent_to: ['B']),
            fake_cell('B', adjacent_to: []),
            fake_cell('C', adjacent_to: ['D']),
            fake_cell('D', adjacent_to: [])
          ]
          registry = FakeProgressRegistry.new(cells, adjacent_pair_keys: ['A:C'])
          built = []
          erased = []
          events = []
          service = AdjacencyService.new(
            registry,
            transition_builder: proc { |cell1, cell2| built << [cell1.id, cell2.id] },
            transition_eraser: proc { |pair_key| erased << pair_key; registry.delete_adjacent_pair(pair_key) }
          )

          metrics = service.synchronize_all(progress: proc { |event| events << event })

          starts = events.select { |event| event[:event] == :stage_start }
          assert_equal [
            :snapshot,
            :candidate_generation,
            :detailed_computation,
            :transition_apply
          ], starts.map { |event| event[:stage] }
          assert_equal [4, 6, 6, 3], starts.map { |event| event[:total] }
          assert_equal [['A', 'B'], ['C', 'D']], built
          assert_equal ['A:C'], erased
          assert_equal ['A:B', 'C:D'], registry.adjacent_pair_keys.sort
          assert_equal 6, metrics[:pair_comparison_count]
          assert_operator metrics[:progress_event_count], :>=, 12
          assert_equal 0, metrics[:progress_error_count]
          assert metrics.key?(:adjacency_snapshot_duration)
          assert metrics.key?(:adjacency_candidate_generation)
          assert metrics.key?(:transition_apply)
        end

        def test_progress_callback_failure_does_not_change_adjacency_result
          cell_a = fake_cell('A', adjacent_to: ['B'])
          cell_b = fake_cell('B')
          registry = FakeProgressRegistry.new([cell_a, cell_b])
          built = []
          service = AdjacencyService.new(
            registry,
            transition_builder: proc { |cell1, cell2| built << [cell1.id, cell2.id] },
            transition_eraser: proc {}
          )

          metrics = service.synchronize_all(progress: proc { |_event| raise 'renderer failed' })

          assert_equal [['A', 'B']], built
          assert_equal ['A:B'], registry.adjacent_pair_keys
          assert_operator metrics[:progress_error_count], :positive?
        end

        private

        def fake_cell(id, adjacent_to: [])
          snapshot = {
            id: id,
            adjacent_to: adjacent_to,
            bounds: { min: [0.0, 0.0, 0.0], max: [1.0, 1.0, 1.0] },
            faces: []
          }.freeze
          entity = Struct.new(:snapshot).new(snapshot)
          state = Struct.new(:valid?).new(true)
          Struct.new(:id, :sketchup_group, :duality_state) do
            def valid?
              true
            end
          end.new(id, entity, state)
        end

        class FakeProgressRegistry
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
