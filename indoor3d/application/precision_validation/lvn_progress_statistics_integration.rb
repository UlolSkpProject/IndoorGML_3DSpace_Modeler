# frozen_string_literal: true

require_relative 'lvn_progress_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        module LvnStatisticsFormatter
          module_function

          def counts(report)
            data = report.respond_to?(:to_h) ? report.to_h : {}
            normalized = data[:cell_space_count].to_i
            failed = data[:normalization_failed_cell_space_count].to_i
            already = data[:already_normalized_cell_space_count].to_i
            previous_failure = data[:skipped_previous_failure_cell_space_count].to_i
            calculated_total = normalized + failed + already + previous_failure
            target_total = data[:target_cell_space_count].to_i
            total = target_total.positive? ? target_total : calculated_total
            skipped = already + previous_failure
            pending = [total - normalized - failed - skipped, 0].max

            {
              total: total,
              normalized: normalized,
              failed: failed,
              already: already,
              previous_failure: previous_failure,
              skipped: skipped,
              pending: pending
            }
          end

          def result_message(report)
            values = counts(report)
            "LVN 결과: 성공 #{format_count(values[:normalized])}" \
              " · 이번 실패 #{format_count(values[:failed])}" \
              " · 기존 완료 #{format_count(values[:already])}" \
              " · 이전 실패 생략 #{format_count(values[:previous_failure])}"
          end

          def step_summary_message(report)
            values = counts(report)
            "전체 #{format_count(values[:total])}개 " \
              "Skip #{format_count(values[:skipped])}개\n" \
              "성공 #{format_count(values[:normalized])}개 " \
              "실패 #{format_count(values[:failed])}개 " \
              "대기 #{format_count(values[:pending])}개"
          end

          def step_summary_tone(report)
            values = counts(report)
            values[:failed].positive? || values[:pending].positive? ? :warning : :success
          end

          def format_count(value)
            value.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
          end
        end

        module ValidationLvnProgressStatisticsAdapterPatch
          def step_summary(message:, tone: :neutral)
            return false unless @progress&.respond_to?(:set_step_summary)

            @progress.set_step_summary(@step, message, tone: tone)
            true
          rescue StandardError => error
            log_error('step summary', error)
            false
          end
        end

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
            summary = LvnStatisticsFormatter.step_summary_message(report)
            @adapter&.step_summary(
              message: summary,
              tone: LvnStatisticsFormatter.step_summary_tone(report)
            )

            emit(
              percent: LvnProgressTracker::FINISH_PERCENT,
              message: LvnStatisticsFormatter.result_message(report)
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
        end

        module LvnProgressStatisticsCommandDispatcherPatch
          private

          def precision_lvn_summary(report)
            LvnStatisticsFormatter.result_message(report)
          end
        end

        def self.install_lvn_progress_statistics!
          adapter_class = ValidationLvnProgressAdapter
          unless adapter_class.ancestors.include?(ValidationLvnProgressStatisticsAdapterPatch)
            adapter_class.prepend(ValidationLvnProgressStatisticsAdapterPatch)
          end

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
