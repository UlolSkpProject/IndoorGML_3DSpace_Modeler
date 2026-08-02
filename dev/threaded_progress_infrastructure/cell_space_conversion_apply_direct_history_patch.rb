# frozen_string_literal: true

require_relative 'cell_space_conversion_apply_history_wait_patch'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionPreflightPrototype
        class Controller
          HISTORY_COMMAND_DELAY = 0.0 unless const_defined?(:HISTORY_COMMAND_DELAY, false)

          unless method_defined?(:start_apply_job_without_direct_history_api)
            alias_method :start_apply_job_without_direct_history_api, :start_apply_job
          end
          unless method_defined?(:status_without_direct_history_api)
            alias_method :status_without_direct_history_api, :status
          end
          unless method_defined?(:close_without_direct_history_api)
            alias_method :close_without_direct_history_api, :close
          end

          def start_apply_job(**options)
            stop_history_command_timer
            start_apply_job_without_direct_history_api(**options)
          end

          def status
            synchronize_history_position_from_runtime
            base = status_without_direct_history_api
            snapshot = base.merge(
              history_command_api: :sketchup_undo_redo,
              history_command_pending: @history_command_action,
              history_command_timer_active: !@history_command_timer_id.nil?
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

            schedule_direct_history_command(:undo)
          rescue StandardError => e
            apply_history_state.reject_undo_request!
            @history_action_error = "#{e.class}: #{e.message}"
            puts "[CELLSPACE APPLY DIRECT HISTORY] Undo scheduling failed: #{@history_action_error}"
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

            schedule_direct_history_command(:redo)
          rescue StandardError => e
            apply_history_state.reject_redo_request!
            @history_action_error = "#{e.class}: #{e.message}"
            puts "[CELLSPACE APPLY DIRECT HISTORY] Redo scheduling failed: #{@history_action_error}"
            false
          end

          def close
            stop_history_command_timer
            close_without_direct_history_api
          end

          private

          def schedule_direct_history_command(action)
            stop_history_command_timer(reject_pending: false)
            @history_command_action = action
            @history_action_error = nil
            @history_command_timer_id = UI.start_timer(HISTORY_COMMAND_DELAY, false) do
              @history_command_timer_id = nil
              execute_direct_history_command(action)
              false
            end
            puts "[CELLSPACE APPLY DIRECT HISTORY] #{action} scheduled after current UI callback"
            true
          end

          def execute_direct_history_command(action)
            assert_main_thread!
            unless Sketchup.active_model.equal?(@job_model)
              raise 'history command cancelled because active model changed'
            end

            case action
            when :undo
              Sketchup.undo
            when :redo
              Sketchup.redo
            else
              raise ArgumentError, "unsupported history action: #{action.inspect}"
            end

            puts "[CELLSPACE APPLY DIRECT HISTORY] Sketchup.#{action} invoked after UI callback"
            schedule_history_monitor(action)
            true
          rescue StandardError => e
            reject_pending_history_request(action)
            @history_action_error = "#{e.class}: #{e.message}"
            puts "[CELLSPACE APPLY DIRECT HISTORY] #{action} failed: #{@history_action_error}"
            false
          ensure
            @history_command_action = nil
          end

          def stop_history_command_timer(reject_pending: true)
            timer_id = @history_command_timer_id
            action = @history_command_action
            @history_command_timer_id = nil
            @history_command_action = nil
            UI.stop_timer(timer_id) if timer_id && UI.respond_to?(:stop_timer)
            reject_pending_history_request(action) if reject_pending && action
            !timer_id.nil?
          rescue StandardError
            false
          end

          def reject_pending_history_request(action)
            case action
            when :undo
              apply_history_state.reject_undo_request!
            when :redo
              apply_history_state.reject_redo_request!
            end
          end

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
puts 'Undo API: deferred Sketchup.undo'
puts 'Redo API: deferred Sketchup.redo'
