# frozen_string_literal: true

require_relative 'prepare_compute_apply_prototype'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrepareComputeApplyPrototype
        class Controller
          unless method_defined?(:status_without_main_thread_sliced_compute_metrics)
            alias_method :status_without_main_thread_sliced_compute_metrics, :status
          end

          unless private_method_defined?(:compute_item_without_main_thread_assertion)
            alias_method :compute_item_without_main_thread_assertion, :compute_item
          end

          unless private_method_defined?(:message_for_without_main_thread_sliced_compute)
            alias_method :message_for_without_main_thread_sliced_compute, :message_for
          end

          def status
            base = status_without_main_thread_sliced_compute_metrics
            job_snapshot = @job&.snapshot || {}
            snapshot = base.merge(
              compute_execution: job_snapshot[:compute_execution],
              compute_thread_id: job_snapshot[:compute_thread_id],
              compute_predictive_budget: job_snapshot[:compute_predictive_budget],
              compute_prediction_safety_factor: job_snapshot[:compute_prediction_safety_factor],
              compute_budget_guard_ms: job_snapshot[:compute_budget_guard_ms],
              compute_estimated_item_ms: job_snapshot[:compute_estimated_item_ms],
              compute_last_item_ms: job_snapshot[:compute_last_item_ms],
              compute_max_item_ms: job_snapshot[:compute_max_item_ms],
              compute_predictive_stop_count: job_snapshot[:compute_predictive_stop_count],
              compute_slice_count: job_snapshot[:compute_slice_count],
              compute_last_slice_items: job_snapshot[:compute_last_slice_items],
              compute_max_slice_items: job_snapshot[:compute_max_slice_items],
              compute_max_slice_ms: job_snapshot[:compute_max_slice_ms],
              compute_overrun_count: job_snapshot[:compute_overrun_count]
            )
            puts "[STAGED JOB MAIN-THREAD COMPUTE] #{snapshot.inspect}"
            snapshot
          end

          private

          def compute_item(input, index)
            assert_main_thread!
            compute_item_without_main_thread_assertion(input, index)
          end

          def message_for(phase, type)
            if phase == :compute && type == :running
              return 'Compute: 메인 스레드 time-slice에서 순수 Ruby 계산 중'
            end

            message_for_without_main_thread_sliced_compute(phase, type)
          end
        end
      end
    end
  end
end

puts '[PREPARE COMPUTE APPLY SLICED PATCH] installed'
puts 'Compute execution: main_thread_sliced + predictive_budget'
