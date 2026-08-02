# frozen_string_literal: true

require_relative 'write_undo_prototype'
require_relative 'write_undo_fault_plan'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module WriteUndoPrototype
        class InjectedApplyFailure < StandardError; end

        class Controller
          unless method_defined?(:start_job_without_fault_injection)
            alias_method :start_job_without_fault_injection, :start_job
            alias_method :status_without_fault_injection, :status
          end

          def start_job(
            mode: :prepare_then_apply,
            item_count: DEFAULT_ITEM_COUNT,
            slice_budget_ms: DEFAULT_SLICE_BUDGET_MS,
            max_items_per_slice: DEFAULT_MAX_ITEMS_PER_SLICE,
            allow_risky: false,
            cancel_after_prepared_items: nil,
            fail_after_created_items: nil
          )
            assert_main_thread!
            return false if running?

            normalized_item_count = [item_count.to_i, 1].max
            fault_plan = ThreadedProgressInfrastructure::WriteUndoFaultPlan.new(
              item_count: normalized_item_count,
              cancel_after_prepared_items: cancel_after_prepared_items,
              fail_after_created_items: fail_after_created_items
            )
            if (fault_plan.cancellation_enabled? || fault_plan.failure_enabled?) &&
               mode.to_sym != :prepare_then_apply
              raise ArgumentError,
                    'fault injection is supported only for prepare_then_apply mode'
            end

            @fault_plan = nil
            @fault_cancel_triggered_at = nil
            @fault_failure_triggered_after = nil

            result = start_job_without_fault_injection(
              mode: mode,
              item_count: normalized_item_count,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice,
              allow_risky: allow_risky
            )
            @fault_plan = fault_plan if result
            result
          end

          def status
            snapshot = status_without_fault_injection
            enriched = snapshot.merge(
              cancel_after_prepared_items: @fault_plan&.cancel_after_prepared_items,
              cancel_triggered_at: @fault_cancel_triggered_at,
              fail_after_created_items: @fault_plan&.fail_after_created_items,
              failure_triggered_after: @fault_failure_triggered_after
            )
            puts "[WRITE UNDO FAULT PROBE] #{enriched.inspect}"
            enriched
          end

          private

          unless private_method_defined?(:build_item_plan_without_fault_injection)
            alias_method :build_item_plan_without_fault_injection, :build_item_plan
            alias_method :add_planned_edge_without_fault_injection, :add_planned_edge
          end

          def build_item_plan(index)
            plan = build_item_plan_without_fault_injection(index)
            trigger_prepare_cancellation(index.to_i + 1)
            plan
          end

          def add_planned_edge(plan)
            trigger_apply_failure
            add_planned_edge_without_fault_injection(plan)
          end

          def trigger_prepare_cancellation(prepared_items)
            return unless @mode_plan&.prepare_then_apply?
            return unless @phase == :prepare
            return unless @fault_plan&.cancel_after_prepare?(prepared_items)
            return unless @fault_cancel_triggered_at.nil?

            @fault_cancel_triggered_at = prepared_items
            @runner&.cancel!
            puts "[WRITE UNDO FAULT PROBE] auto-cancel after #{prepared_items} prepared items"
          end

          def trigger_apply_failure
            return unless @mode_plan&.prepare_then_apply?
            return unless @phase == :apply
            return unless @fault_plan&.fail_before_next_create?(@created_items)
            return unless @fault_failure_triggered_after.nil?

            @fault_failure_triggered_after = @created_items
            raise InjectedApplyFailure,
                  "injected apply failure after #{@created_items} created items"
          end
        end

        class << self
          def start!(
            mode: :prepare_then_apply,
            item_count: DEFAULT_ITEM_COUNT,
            slice_budget_ms: DEFAULT_SLICE_BUDGET_MS,
            max_items_per_slice: DEFAULT_MAX_ITEMS_PER_SLICE,
            allow_risky: false,
            cancel_after_prepared_items: nil,
            fail_after_created_items: nil
          )
            controller.start_job(
              mode: mode,
              item_count: item_count,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice,
              allow_risky: allow_risky,
              cancel_after_prepared_items: cancel_after_prepared_items,
              fail_after_created_items: fail_after_created_items
            )
          end

          def start_cancel_probe!(
            item_count: 5_000,
            cancel_after_prepared_items: 250,
            slice_budget_ms: DEFAULT_SLICE_BUDGET_MS,
            max_items_per_slice: DEFAULT_MAX_ITEMS_PER_SLICE
          )
            start!(
              mode: :prepare_then_apply,
              item_count: item_count,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice,
              cancel_after_prepared_items: cancel_after_prepared_items
            )
          end

          def start_failure_probe!(
            item_count: DEFAULT_ITEM_COUNT,
            fail_after_created_items: 120,
            slice_budget_ms: DEFAULT_SLICE_BUDGET_MS,
            max_items_per_slice: DEFAULT_MAX_ITEMS_PER_SLICE
          )
            start!(
              mode: :prepare_then_apply,
              item_count: item_count,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice,
              fail_after_created_items: fail_after_created_items
            )
          end
        end
      end
    end
  end
end

puts '[WRITE UNDO FAILURE PATCH] installed'
puts 'Cancel probe : ...::WriteUndoPrototype.start_cancel_probe!'
puts 'Failure probe: ...::WriteUndoPrototype.start_failure_probe!'
