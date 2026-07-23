# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/application/indoor_model/topology'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ValidationFocusTopologySyncTest < Minitest::Test
        def test_active_row_cell_change_uses_local_sync_and_marks_dirty
          cells = [fake_cell('A'), fake_cell('B'), fake_cell('C'), fake_cell('D')]
          model = FakeIndoorModel.new(cells: cells, row_cells: %w[A B])

          model.mark_dirty(cells[0])

          assert_equal [%w[A B]], model.coordinator.within_calls.map { |items| items.map(&:id) }
          assert_equal 0, model.coordinator.all_count
          assert model.validation_focus_topology_dirty?
        end

        def test_cell_outside_active_row_marks_dirty_without_local_sync
          cells = [fake_cell('A'), fake_cell('B'), fake_cell('C')]
          model = FakeIndoorModel.new(cells: cells, row_cells: %w[A B])

          model.mark_dirty(cells[2])

          assert_empty model.coordinator.within_calls
          assert_equal 0, model.coordinator.all_count
          assert model.validation_focus_topology_dirty?
        end

        def test_created_cell_sync_uses_updated_active_row
          cells = [fake_cell('A'), fake_cell('B')]
          model = FakeIndoorModel.new(cells: cells, row_cells: %w[A B])

          model.sync_created(cells[1])

          assert_equal [%w[A B]], model.coordinator.within_calls.map { |items| items.map(&:id) }
          assert_equal 0, model.coordinator.all_count
          assert model.validation_focus_topology_dirty?
        end

        def test_deleted_cell_erases_stale_pairs_without_full_sync
          cell = fake_cell('A')
          model = FakeIndoorModel.new(cells: [], row_cells: ['B'])

          model.erase(cell)

          assert_equal ['A'], model.coordinator.erased_ids
          assert_equal 0, model.coordinator.all_count
          assert model.validation_focus_topology_dirty?
        end

        def test_mutation_batch_coalesces_local_sync
          cells = [fake_cell('A'), fake_cell('B')]
          model = FakeIndoorModel.new(cells: cells, row_cells: %w[A B])

          model.begin_batch
          model.sync_created(cells[0])
          model.sync_created(cells[1])
          assert_empty model.coordinator.within_calls
          model.end_batch

          assert_equal [%w[A B]], model.coordinator.within_calls.map { |items| items.map(&:id) }
          assert model.validation_focus_topology_dirty?
        end

        def test_dirty_full_sync_clears_flag_only_after_success
          model = FakeIndoorModel.new(cells: [], row_cells: [])
          model.mark_validation_focus_topology_dirty

          assert model.synchronize_validation_focus_topology_if_dirty
          assert_equal 1, model.coordinator.all_count
          refute model.validation_focus_topology_dirty?

          failing = FakeIndoorModel.new(cells: [], row_cells: [], fail_all: true)
          failing.mark_validation_focus_topology_dirty

          refute failing.synchronize_validation_focus_topology_if_dirty
          assert failing.validation_focus_topology_dirty?
        end

        private

        def fake_cell(id)
          Struct.new(:id) do
            def valid?
              true
            end
          end.new(id)
        end

        class FakeIndoorModel
          include IndoorModel::Topology

          attr_reader :coordinator

          def initialize(cells:, row_cells:, fail_all: false)
            @cells = cells
            @row_cells = row_cells
            @coordinator = FakeCoordinator.new(fail_all: fail_all)
            @topology_coordinator = @coordinator
            @editor_session = FakeEditorSession.new(row_cells)
          end

          def cell_spaces
            @cells
          end

          def validation_focus_active?
            true
          end

          def validation_focus_highlight_cell_spaces
            @cells.select { |cell| @row_cells.include?(cell.id) }
          end

          def mark_dirty(cell)
            send(:mark_cell_space_dirty, cell)
          end

          def sync_created(cell)
            send(:synchronize_adjacency_and_transitions_for_cell_space, cell)
          end

          def erase(cell)
            send(:erase_adjacency_for_cell_space, cell)
          end

          def begin_batch
            @validation_focus_mutation_depth = 1
          end

          def end_batch
            @validation_focus_mutation_depth = 0
            flush_validation_focus_row_topology_sync
          end

          def invalidate_overlay_transition_points; end

          def with_indoor_model_operation(_name)
            yield
          end

          def sync
            yield
          end
        end

        class FakeEditorSession
          def initialize(row_cells)
            @row_cells = row_cells
          end

          def validation_focus_highlight_row_id
            'row-1'
          end

          def validation_focus_highlight_row_include_cell?(cell)
            @row_cells.include?(cell.id)
          end
        end

        class FakeCoordinator
          attr_reader :within_calls, :all_count, :erased_ids, :dirty_queue

          def initialize(fail_all: false)
            @within_calls = []
            @all_count = 0
            @erased_ids = []
            @fail_all = fail_all
            @dirty_queue = DirtyTopologyQueue.new
          end

          def synchronize_within(cells)
            @within_calls << cells
            { pair_comparison_count: cells.length * (cells.length - 1) / 2 }
          end

          def synchronize_all
            @all_count += 1
            raise 'full sync failed' if @fail_all

            {}
          end

          def erase_for(cell)
            @erased_ids << cell.id
          end
        end
      end
    end
  end
end
