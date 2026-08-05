# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      module PrecisionValidation; end

      CellSpace = Struct.new(:id)

      class TopologyCoordinator
        attr_reader :calls

        def initialize
          @calls = 0
        end

        def synchronize_all
          @calls += 1
          { synchronized: true }
        end
      end

      class IndoorModel
        attr_reader :topology_coordinator

        def initialize
          @topology_coordinator = TopologyCoordinator.new
        end

        def local_vertex_normalize(_tolerance = 0.001, cell_spaces: nil, **_options)
          targets = normalization_targets(cell_spaces)
          plan = build_continue_execution_plan(targets, 0.001)
          local_vertex_normalize_continue_per_cell(
            0.001,
            targets,
            plan[:rows],
            plan[:execution_targets]
          )
        end

        private

        def normalization_targets(cell_spaces)
          Array(cell_spaces)
        end

        def build_continue_execution_plan(targets, _tolerance)
          { rows: [], execution_targets: targets }
        end

        def local_vertex_normalize_continue_per_cell(
          _tolerance,
          _targets,
          initial_rows,
          execution_targets
        )
          rows = Array(initial_rows).dup
          execution_targets.each do |cell_space|
            rows << normalize_cell_space_continue(cell_space)
          end
          successful = rows.count { |row| row[:status] == :normalized }
          topology = topology_coordinator.synchronize_all if successful.positive?
          {
            cell_space_count: successful,
            already_normalized_cell_space_count: 0,
            normalization_failed_cell_space_count: rows.count { |row| row[:status] == :failed },
            skipped_previous_failure_cell_space_count: 0,
            topology_metrics: topology,
            cell_spaces: rows
          }
        end

        def normalize_cell_space_continue(cell_space)
          status = cell_space.id == 'B' ? :failed : :normalized
          { status: status, cell_space_id: cell_space.id }
        end
      end

      class CommandDispatcher
        private

        def precision_validation_session?(session)
          session.state[:validation_profile] == :precision
        end

        def perform_check_validity(session)
          session.progress.detail(
            :lvn,
            percent: 0,
            phase: 'CellSpace Normalize',
            message: 'start'
          )
          report = session.indoor_model.local_vertex_normalize(
            cell_spaces: session.cells,
            failure_policy: :continue
          )
          session.progress.detail(
            :lvn,
            percent: 100,
            phase: 'CellSpace Normalize',
            message: 'done'
          )
          report
        end
      end
    end
  end
end

require_relative '../indoor3d/application/precision_validation/lvn_progress_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationLvnProgressIntegrationTest < Minitest::Test
        class Progress
          attr_reader :details

          def initialize
            @details = []
          end

          def detail(step, **payload)
            @details << payload.merge(step: step)
          end
        end

        Session = Struct.new(:state, :progress, :indoor_model, :cells)

        def test_precision_lvn_uses_shared_dialog_detail_progress
          progress = Progress.new
          model = IndoorModel.new
          cells = %w[A B C].map { |id| CellSpace.new(id) }
          session = Session.new(
            { validation_profile: :precision },
            progress,
            model,
            cells
          )

          report = CommandDispatcher.new.send(:perform_check_validity, session)

          percentages = progress.details.map { |payload| payload[:percent] }
          assert_equal 0, percentages.first
          assert_equal 100, percentages.last
          assert percentages.any? { |value| value.between?(1, 99) }
          assert_equal percentages.sort, percentages
          assert_equal %w[A B C], progress.details.filter_map { |payload| payload[:current] }.uniq
          assert progress.details.any? { |payload| payload[:phase] == 'Topology Synchronize' }
          assert_equal 2, report[:cell_space_count]
          assert_equal 1, report[:normalization_failed_cell_space_count]
          assert_equal 1, model.topology_coordinator.calls
          assert_nil PrecisionValidation::LvnProgressContext.current
        end

        def test_context_restores_previous_tracker_after_error
          previous = Object.new
          current = Object.new
          key = PrecisionValidation::LvnProgressContext::THREAD_KEY
          Thread.current[key] = previous

          assert_raises(RuntimeError) do
            PrecisionValidation::LvnProgressContext.with(current) do
              assert_same current, PrecisionValidation::LvnProgressContext.current
              raise 'forced'
            end
          end

          assert_same previous, PrecisionValidation::LvnProgressContext.current
        ensure
          Thread.current[key] = nil if key
        end

        def test_failed_cell_keeps_progress_monotonic_and_continues
          progress = Progress.new
          tracker = PrecisionValidation::LvnProgressTracker.new(
            PrecisionValidation::ValidationLvnProgressAdapter.new(progress)
          )
          cells = %w[A B C].map { |id| CellSpace.new(id) }

          tracker.start(total: cells.length)
          tracker.plan_ready(rows: [], execution_targets: cells)
          tracker.begin_cells(total: cells.length)
          tracker.cell_finished(cells[0])
          tracker.cell_finished(cells[1], status: :failed)
          tracker.cell_finished(cells[2])
          tracker.cells_completed
          tracker.topology_started
          tracker.topology_finished
          tracker.finish(cell_space_count: 2, normalization_failed_cell_space_count: 1)

          percentages = progress.details.map { |payload| payload[:percent] }
          assert_equal percentages.sort, percentages
          assert progress.details.any? do |payload|
            payload[:message].to_s.include?('failed; rollback completed')
          end
          assert_operator percentages.last, :<, 100
        end

        def test_adaptive_checkpoint_limits_large_cell_updates
          progress = Progress.new
          tracker = PrecisionValidation::LvnProgressTracker.new(
            PrecisionValidation::ValidationLvnProgressAdapter.new(progress)
          )
          tracker.start(total: 1000)
          tracker.plan_ready(rows: [], execution_targets: Array.new(1000))
          tracker.begin_cells(total: 1000)
          1000.times do |index|
            tracker.cell_finished(CellSpace.new(index.to_s))
          end

          cell_updates = progress.details.count do |payload|
            payload[:message].to_s.start_with?('CellSpace Normalize:')
          end
          assert_operator cell_updates, :<=, 102
        end
      end
    end
  end
end
