# frozen_string_literal: true
# encoding: UTF-8

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      module PrecisionValidation; end

      class CommandDispatcher
        private

        def precision_lvn_summary(_report)
          'legacy summary'
        end
      end
    end
  end
end

require_relative '../indoor3d/application/precision_validation/lvn_progress_statistics_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationLvnProgressStatisticsIntegrationTest < Minitest::Test
        class Progress
          attr_reader :details

          def initialize
            @details = []
          end

          def detail(step, **payload)
            @details << payload.merge(step: step)
          end
        end

        def setup
          @progress = Progress.new
          @tracker = PrecisionValidation::LvnProgressTracker.new(
            PrecisionValidation::ValidationLvnProgressAdapter.new(@progress)
          )
        end

        def test_plan_and_progress_show_execution_and_skip_statistics
          rows = [
            { status: :already_normalized },
            { status: :already_normalized },
            { status: :skipped_previous_failure }
          ]

          @tracker.start(total: 9)
          @tracker.plan_ready(rows: rows, execution_targets: Array.new(6))
          @tracker.begin_cells(total: 6)

          messages = @progress.details.map { |detail| detail[:message] }
          assert_includes(
            messages,
            'LVN 계획: 전체 9 · 실행 6 · 기존 완료 2 · 이전 실패 생략 1'
          )
          assert_includes(
            messages,
            'CellSpace Normalize: 0 / 6 · 기존 완료 2 · 이전 실패 생략 1'
          )
          assert_equal(
            'CellSpace Normalize: 3 / 6 · 현재 대상 실패(rollback 완료) · 기존 완료 2 · 이전 실패 생략 1',
            @tracker.send(:phase_message, 3, status: :failed)
          )
        end

        def test_finish_and_final_summary_use_same_statistics_format
          report = {
            cell_space_count: 5,
            normalization_failed_cell_space_count: 1,
            already_normalized_cell_space_count: 2,
            skipped_previous_failure_cell_space_count: 1
          }
          expected = 'LVN 결과: 성공 5 · 이번 실패 1 · 기존 완료 2 · 이전 실패 생략 1'

          @tracker.start(total: 9)
          @tracker.finish(report)

          assert_equal expected, @progress.details.last[:message]
          assert_equal(
            expected,
            CommandDispatcher.new.send(:precision_lvn_summary, report)
          )
        end
      end
    end
  end
end
