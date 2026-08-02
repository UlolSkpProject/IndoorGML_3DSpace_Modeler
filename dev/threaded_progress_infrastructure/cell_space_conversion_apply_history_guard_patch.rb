# frozen_string_literal: true

require_relative 'cell_space_conversion_progress_apply_safety_patch'
require_relative 'cell_space_conversion_apply_history_state'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionPreflightPrototype
        class Controller
          unless method_defined?(:start_apply_job_without_history_guard)
            alias_method :start_apply_job_without_history_guard, :start_apply_job
          end
          unless method_defined?(:status_without_history_guard)
            alias_method :status_without_history_guard, :status
          end
          unless private_method_defined?(:perform_apply_without_history_guard)
            alias_method :perform_apply_without_history_guard, :perform_apply
          end

          def start_apply_job(**options)
            @apply_history_state = new_apply_history_state
            start_apply_job_without_history_guard(**options)
          end

          def status
            base = status_without_history_guard
            snapshot = base.merge(
              apply_history_position: apply_history_state.position,
              apply_history_available: apply_history_state.apply_recorded?
            ).freeze
            puts "[CELLSPACE APPLY HISTORY GUARD] #{snapshot.inspect}"
            snapshot
          end

          def verify_apply(expected = :converted)
            assert_main_thread!
            expected = expected.to_sym
            current = feature_counts(@indoor_model || IndoorModel.current)
            converted = @apply_result ? @apply_result.converted_count.to_i : 0
            before_matches = @before_feature_counts.is_a?(Hash) && current == @before_feature_counts
            after_matches = @after_feature_counts.is_a?(Hash) && current == @after_feature_counts
            reason = nil

            passed = case expected
                     when :converted
                       if !apply_history_state.apply_recorded?
                         reason = :no_apply_history
                         false
                       elsif @apply_phase != :completed
                         reason = :apply_not_completed
                         false
                       else
                         converted.positive? &&
                           @before_feature_counts &&
                           current[:cell_spaces] == @before_feature_counts[:cell_spaces] + converted &&
                           current[:states] == @before_feature_counts[:states] + converted
                       end
                     when :undone
                       if %i[undo_requested undone].include?(apply_history_state.position)
                         verified = apply_history_state.confirm_undone!(matches: before_matches)
                         reason = :undo_result_mismatch unless verified
                         verified
                       else
                         reason = :undo_not_requested
                         false
                       end
                     when :redone
                       if %i[redo_requested redone].include?(apply_history_state.position)
                         verified = apply_history_state.confirm_redone!(matches: after_matches)
                         reason = :redo_result_mismatch unless verified
                         verified
                       else
                         reason = :redo_not_requested
                         false
                       end
                     when :not_applied
                       if apply_history_state.apply_recorded?
                         reason = :apply_history_exists
                         false
                       else
                         before_matches
                       end
                     else
                       raise ArgumentError, "unsupported expected state: #{expected}"
                     end

            passed = passed == true
            payload = {
              expected: expected,
              converted_count: converted,
              apply_phase: @apply_phase,
              apply_history_position: apply_history_state.position,
              apply_history_available: apply_history_state.apply_recorded?,
              reason: reason,
              feature_counts_before: @before_feature_counts,
              feature_counts_after_apply: @after_feature_counts,
              feature_counts_current: current,
              passed: passed
            }.freeze
            puts "[CELLSPACE PROGRESS APPLY VERIFY] #{payload.inspect}"
            payload
          end

          def undo_apply
            assert_main_thread!
            unless apply_history_state.request_undo!
              puts "[CELLSPACE APPLY HISTORY GUARD] Undo blocked: position=#{apply_history_state.position}"
              return false
            end

            dispatched = Sketchup.send_action('editUndo:')
            if dispatched == false
              apply_history_state.reject_undo_request!
              puts '[CELLSPACE APPLY HISTORY GUARD] Undo dispatch failed'
              return false
            end

            invalidate_view
            true
          end

          def redo_apply
            assert_main_thread!
            unless apply_history_state.request_redo!
              puts "[CELLSPACE APPLY HISTORY GUARD] Redo blocked: position=#{apply_history_state.position}"
              return false
            end

            dispatched = Sketchup.send_action('editRedo:')
            if dispatched == false
              apply_history_state.reject_redo_request!
              puts '[CELLSPACE APPLY HISTORY GUARD] Redo dispatch failed'
              return false
            end

            invalidate_view
            true
          end

          private

          def perform_apply
            result = perform_apply_without_history_guard
            if apply_changed_model?
              apply_history_state.mark_applied!
            else
              apply_history_state.mark_not_applied!
            end
            result
          rescue StandardError
            apply_history_state.mark_not_applied!
            raise
          end

          def apply_changed_model?
            return false unless @apply_result
            return false unless @apply_result.converted_count.to_i.positive?
            return false unless @before_feature_counts.is_a?(Hash)
            return false unless @after_feature_counts.is_a?(Hash)

            @after_feature_counts != @before_feature_counts
          end

          def apply_history_state
            @apply_history_state ||= new_apply_history_state
          end

          def new_apply_history_state
            ThreadedProgressInfrastructure::CellSpaceConversionApplyHistoryState.new
          end
        end
      end
    end
  end
end

puts '[CELLSPACE CONVERSION APPLY HISTORY GUARD PATCH] installed'
