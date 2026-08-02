# frozen_string_literal: true

require_relative 'cell_space_conversion_rollback_failure_runner'
require_relative 'cell_space_conversion_rollback_verification_policy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionRollbackFailureRunner
        class << self
          private

          def finalize!(context)
            model = context.fetch(:model)
            indoor_model = context.fetch(:indoor_model)
            probe = context.fetch(:probe)
            model.remove_observer(probe)
            restore_active_path(indoor_model, model, context[:initial_active_path])

            after = capture_model_state(model, indoor_model)
            sources_after = context.fetch(:source_snapshots).map do |snapshot|
              entity = find_entity(model, snapshot[:persistent_id])
              entity ? source_snapshot(entity) : nil
            end
            source_snapshot_unchanged = sources_after == context.fetch(:source_snapshots)
            root_entities_unchanged = after[:root_entity_ids] == context.dig(:before, :root_entity_ids)
            feature_counts_unchanged = after[:feature_counts] == context.dig(:before, :feature_counts)
            active_path_restored = after[:active_path] == context.dig(:before, :active_path)
            replay_idle = indoor_model.transaction_replay_pending? != true
            unexpected_error = context[:unexpected_error]

            policy =
              ThreadedProgressInfrastructure::
                CellSpaceConversionRollbackVerificationPolicy.new
            decision = policy.evaluate(
              expected_failure: context[:expected_failure],
              unexpected_error: unexpected_error,
              injection_hits: context[:injection_hits],
              service_returned: !context[:service_result].nil?,
              root_entities_unchanged: root_entities_unchanged,
              feature_counts_unchanged: feature_counts_unchanged,
              source_snapshot_unchanged: source_snapshot_unchanged,
              active_path_restored: active_path_restored,
              replay_idle: replay_idle,
              observer_events: probe.events
            )
            observer = decision.fetch(:observer)
            counts = observer.fetch(:counts)

            @last_result = {
              type: decision[:passed] ? :completed : :failed,
              passed: decision[:passed],
              injected_failure_caught: context[:expected_failure] == true,
              injection_hits: context[:injection_hits],
              unexpected_error_class: unexpected_error&.class&.name,
              unexpected_error_message: unexpected_error&.message,
              service_returned: !context[:service_result].nil?,
              job_count: context.fetch(:jobs).length,
              feature_counts_before: context.dig(:before, :feature_counts),
              feature_counts_after: after[:feature_counts],
              feature_counts_unchanged: feature_counts_unchanged,
              root_entity_count_before: context.dig(:before, :root_entity_ids).length,
              root_entity_count_after: after[:root_entity_ids].length,
              root_entities_unchanged: root_entities_unchanged,
              source_snapshot_unchanged: source_snapshot_unchanged,
              sources_still_valid: sources_after.none?(&:nil?),
              active_path_restored: active_path_restored,
              transaction_replay_pending: indoor_model.transaction_replay_pending? == true,
              observer_events: observer[:events],
              transaction_start_count: counts[:start],
              transaction_abort_count: counts[:abort],
              transaction_commit_count: counts[:commit],
              transaction_empty_count: counts[:empty],
              transaction_undo_count: counts[:undo],
              transaction_redo_count: counts[:redo],
              transaction_rollback_signal: observer[:rollback_signal],
              transaction_rollback_signal_present: observer[:rollback_signal_present],
              transaction_not_committed: observer[:transaction_not_committed],
              transaction_observer_consistent: observer[:consistent],
              transaction_abort_clean: observer[:consistent],
              rollback_hard_gates: decision[:hard_gates]
            }.freeze
            puts "[CELLSPACE ROLLBACK FAILURE RESULT] #{@last_result.inspect}"
            @last_result
          rescue StandardError => e
            @last_result = failure_payload(:verification_failed, e)
            puts "[CELLSPACE ROLLBACK FAILURE] verification failed: #{e.class}: #{e.message}"
            @last_result
          ensure
            @running = false
          end
        end
      end
    end
  end
end

puts '[CELLSPACE CONVERSION ROLLBACK VERIFICATION PATCH] installed'
