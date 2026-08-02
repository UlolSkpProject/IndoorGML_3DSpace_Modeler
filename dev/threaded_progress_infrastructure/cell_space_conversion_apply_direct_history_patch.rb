# frozen_string_literal: true

require_relative 'cell_space_conversion_apply_history_wait_patch'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionPreflightPrototype
        class Controller
          unless method_defined?(:status_without_direct_history_api)
            alias_method :status_without_direct_history_api, :status
          end

          def status
            synchronize_history_position_from_runtime
            base = status_without_direct_history_api
            snapshot = base.merge(
              history_command_api: :sketchup_undo_redo
            ).freeze
            puts "[CELLSPACE APPLY DIRECT HISTORY] #{snapshot.inspect}"
            snapshot
          end

          def undo_apply
            assert_main_thread!
            synchronize_history_position_from_runtime
            if apply_history_state.position == :undone
              puts '[CELLSPACE APPLY DIRECT HISTORY] Undo skipped: runtime is already at the pre-apply snapshot'
              return true
            end

            unless apply_history_state.request_undo!
              puts "[CELLSPACE APPLY DIRECT HISTORY] Undo blocked: position=#{apply_history_state.position}"
              return false
            end

            Sketchup.undo
            schedule_history_monitor(:undo)
            puts '[CELLSPACE APPLY DIRECT HISTORY] Sketchup.undo invoked'
            true
          rescue StandardError => e
            apply_history_state.reject_undo_request!
            @history_action_error = "#{e.class}: #{e.message}"
            puts "[CELLSPACE APPLY DIRECT HISTORY] Undo failed: #{@history_action_error}"
            false
          end

          def redo_apply
            assert_main_thread!
            synchronize_history_position_from_runtime
            if apply_history_state.position == :redone
              puts '[CELLSPACE APPLY DIRECT HISTORY] Redo skipped: runtime is already at the post-apply snapshot'
              return true
            end

            unless apply_history_state.request_redo!
              puts "[CELLSPACE APPLY DIRECT HISTORY] Redo blocked: position=#{apply_history_state.position}"
              return false
            end

            Sketchup.redo
            schedule_history_monitor(:redo)
            puts '[CELLSPACE APPLY DIRECT HISTORY] Sketchup.redo invoked'
            true
          rescue StandardError => e
            apply_history_state.reject_redo_request!
            @history_action_error = "#{e.class}: #{e.message}"
            puts "[CELLSPACE APPLY DIRECT HISTORY] Redo failed: #{@history_action_error}"
            false
          end

          private

          def synchronize_history_position_from_runtime
            return false unless @indoor_model

            current = feature_counts(@indoor_model)
            if @before_feature_counts.is_a?(Hash) && current == @before_feature_counts
              synchronize_history_to_undone
            elsif @after_feature_counts.is_a?(Hash) && current == @after_feature_counts
              synchronize_history_to_after_apply
            end
            true
          rescue StandardError => e
            puts "[CELLSPACE APPLY DIRECT HISTORY] runtime state sync skipped: #{e.class}: #{e.message}"
            false
          end

          def synchronize_history_to_undone
            case apply_history_state.position
            when :applied, :redone
              return unless apply_history_state.request_undo!

              apply_history_state.confirm_undone!(matches: true)
            when :undo_requested
              apply_history_state.confirm_undone!(matches: true)
            end
          end

          def synchronize_history_to_after_apply
            case apply_history_state.position
            when :undone
              return unless apply_history_state.request_redo!

              apply_history_state.confirm_redone!(matches: true)
            when :redo_requested
              apply_history_state.confirm_redone!(matches: true)
            end
          end
        end
      end
    end
  end
end

puts '[CELLSPACE CONVERSION APPLY DIRECT HISTORY PATCH] installed'
puts 'Undo API: Sketchup.undo'
puts 'Redo API: Sketchup.redo'
