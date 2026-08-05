# frozen_string_literal: true

require_relative 'lvn_progress_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        module LvnProgressStatisticsTrackerPatch
          def plan_ready(rows:, execution_targets:)
            records = Array(rows)
            @already_normalized_count = records.count do |row|
              row[:status] == :already_normalized
            end
            @previous_failure_count = records.count do |row|
              row[:status] == :skipped_previous_failure
            end
            @execution_target_count = Array(execution_targets).length

            emit(
              percent: LvnProgressTracker::PLAN_PERCENT,
              message: lvn_plan_statistics_message
            )
          rescue StandardError
            super
          end

          def begin_cells(total:)
            result = super
            emit(
              percent: @last_percent,
              message: phase_message(0)
            )
            result
          end

          def cells_completed
            return false unless @phase == :cells

            emit(
              percent: [@last_percent, LvnProgressTracker::CELL_END_PERCENT].max,
              message: phase_message(@phase_total)
            )
          end

          def finish(report = nil)
            data = report.respond_to?(:to_h) ? report.to_h : {}
            normalized = data[:cell_space_count].to_i
            failed = data[:normalization_failed_cell_space_count].to_i
            already = data[:already_normalized_cell_space_count].to_i
            previous_failure = data[:skipped_previous_failure_cell_space_count].to_i

            emit(
              percent: LvnProgressTracker::FINISH_PERCENT,
              message: lvn_result_statistics_message(
                normalized: normalized,
                failed: failed,
                already: already,
                previous_failure: previous_failure
              )
            )
          end

          private

          def reset
            super
            @already_normalized_count = 0
            @previous_failure_count = 0
            @execution_target_count = 0
          end

          def phase_message(completed, status: nil)
            failure = status == :failed ? ' · 현재 대상 실패(rollback 완료)' : ''
            "CellSpace Normalize: #{completed} / #{@phase_total}#{failure}" \
              " · 기존 완료 #{@already_normalized_count}" \
              " · 이전 실패 생략 #{@previous_failure_count}"
          end

          def lvn_plan_statistics_message
            "LVN 계획: 전체 #{@total_targets}" \
              " · 실행 #{@execution_target_count}" \
              " · 기존 완료 #{@already_normalized_count}" \
              " · 이전 실패 생략 #{@previous_failure_count}"
          end

          def lvn_result_statistics_message(normalized:, failed:, already:, previous_failure:)
            "LVN 결과: 성공 #{normalized}" \
              " · 이번 실패 #{failed}" \
              " · 기존 완료 #{already}" \
              " · 이전 실패 생략 #{previous_failure}"
          end
        end

        module LvnProgressStatisticsCommandDispatcherPatch
          private

          def precision_lvn_summary(report)
            data = report || {}
            normalized = data[:cell_space_count].to_i
            failed = data[:normalization_failed_cell_space_count].to_i
            already = data[:already_normalized_cell_space_count].to_i
            previous_failure = data[:skipped_previous_failure_cell_space_count].to_i

            "LVN 결과: 성공 #{normalized}" \
              " · 이번 실패 #{failed}" \
              " · 기존 완료 #{already}" \
              " · 이전 실패 생략 #{previous_failure}"
          end
        end

        def self.install_lvn_progress_statistics!
          tracker_class = LvnProgressTracker
          unless tracker_class.ancestors.include?(LvnProgressStatisticsTrackerPatch)
            tracker_class.prepend(LvnProgressStatisticsTrackerPatch)
          end

          if defined?(CommandDispatcher) &&
             !CommandDispatcher.ancestors.include?(LvnProgressStatisticsCommandDispatcherPatch)
            CommandDispatcher.prepend(LvnProgressStatisticsCommandDispatcherPatch)
          end

          true
        end
      end

      PrecisionValidation.install_lvn_progress_statistics!
    end
  end
end
