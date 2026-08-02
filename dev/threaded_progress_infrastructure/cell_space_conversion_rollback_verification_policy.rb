# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class CellSpaceConversionRollbackVerificationPolicy
          def evaluate(
            expected_failure:,
            unexpected_error:,
            injection_hits:,
            service_returned:,
            root_entities_unchanged:,
            feature_counts_unchanged:,
            source_snapshot_unchanged:,
            active_path_restored:,
            replay_idle:,
            observer_events:
          )
            events = Array(observer_events).map(&:to_sym)
            counts = event_counts(events)
            rollback_signal = rollback_signal(counts)
            transaction_not_committed =
              counts[:commit].zero? &&
              counts[:empty].zero? &&
              counts[:redo].zero?

            hard_gates = {
              expected_failure_caught: expected_failure == true,
              no_unexpected_error: unexpected_error.nil?,
              injection_hit_once: injection_hits.to_i == 1,
              service_did_not_return: service_returned != true,
              root_entities_unchanged: root_entities_unchanged == true,
              feature_counts_unchanged: feature_counts_unchanged == true,
              source_snapshot_unchanged: source_snapshot_unchanged == true,
              active_path_restored: active_path_restored == true,
              replay_idle: replay_idle == true,
              transaction_not_committed: transaction_not_committed
            }.freeze

            observer = {
              events: events.freeze,
              counts: counts.freeze,
              rollback_signal: rollback_signal,
              rollback_signal_present: rollback_signal != :none,
              transaction_not_committed: transaction_not_committed,
              consistent:
                transaction_not_committed &&
                counts[:start].positive? &&
                rollback_signal != :none
            }.freeze

            {
              passed: hard_gates.values.all?,
              hard_gates: hard_gates,
              observer: observer
            }.freeze
          end

          private

          def event_counts(events)
            %i[start commit empty abort undo redo].each_with_object({}) do |event, counts|
              counts[event] = events.count(event)
            end
          end

          def rollback_signal(counts)
            return :abort_callback if counts[:abort].positive?
            return :undo_callback if counts[:undo].positive?

            :none
          end
        end
      end
    end
  end
end
