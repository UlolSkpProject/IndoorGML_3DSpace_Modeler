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
          attr_reader :details, :step_summaries

          def initialize
            @details = []
            @step_summaries = []
          end

          def detail(step, **payload)
            @details << payload.merge(step: step)
          end

          def set_step_summary(step, message, tone: :neutral)
            @step_summaries << {
              step: step,
              message: message,
              tone: tone
            }
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

        def test_finish_persists_two_line_statistics_below_lvn_step
          report = {
            target_cell_space_count: 1_243,
            cell_space_count: 431,
            normalization_failed_cell_space_count: 8,
            already_normalized_cell_space_count: 781,
            skipped_previous_failure_cell_space_count: 23
          }

          @tracker.start(total: 1_243)
          @tracker.finish(report)

          assert_equal(
            {
              step: :lvn,
              message: "전체 1,243개 Skip 804개\n성공 431개 실패 8개 대기 0개",
              tone: :warning
            },
            @progress.step_summaries.last
          )
          assert_equal(
            'LVN 결과: 성공 431 · 이번 실패 8 · 기존 완료 781 · 이전 실패 생략 23',
            @progress.details.last[:message]
          )
          assert_equal(
            'LVN 결과: 성공 431 · 이번 실패 8 · 기존 완료 781 · 이전 실패 생략 23',
            CommandDispatcher.new.send(:precision_lvn_summary, report)
          )
        end

        def test_pending_is_remaining_unclassified_target_count
          report = {
            target_cell_space_count: 10,
            cell_space_count: 3,
            normalization_failed_cell_space_count: 1,
            already_normalized_cell_space_count: 3,
            skipped_previous_failure_cell_space_count: 1
          }

          @tracker.finish(report)

          assert_equal(
            "전체 10개 Skip 4개\n성공 3개 실패 1개 대기 2개",
            @progress.step_summaries.last[:message]
          )
          assert_equal :warning, @progress.step_summaries.last[:tone]
        end

        def test_zero_failure_and_zero_pending_summary_uses_success_tone
          report = {
            target_cell_space_count: 5,
            cell_space_count: 3,
            normalization_failed_cell_space_count: 0,
            already_normalized_cell_space_count: 2,
            skipped_previous_failure_cell_space_count: 0
          }

          @tracker.finish(report)

          assert_equal :success, @progress.step_summaries.last[:tone]
          assert_equal(
            "전체 5개 Skip 2개\n성공 3개 실패 0개 대기 0개",
            @progress.step_summaries.last[:message]
          )
        end
      end
    end
  end
end
