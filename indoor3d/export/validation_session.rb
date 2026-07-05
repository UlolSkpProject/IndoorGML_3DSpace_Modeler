# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ValidationSession
          EXPIRED_MESSAGE = '원본 모델이 닫혀 이 검사 결과는 더 이상 사용할 수 없습니다. 해당 모델에서 검사를 다시 실행하세요.'

          class << self
            def sessions_by_model_id
              @sessions_by_model_id ||= {}
            end

            def register(session)
              return unless session&.model_id

              sessions_by_model_id[session.model_id] = session
            end

            def unregister(session)
              return unless session&.model_id
              return unless sessions_by_model_id[session.model_id].equal?(session)

              sessions_by_model_id.delete(session.model_id)
            end

            def for_model(model)
              sessions_by_model_id[model&.object_id]
            end

            def cancel_for_model(model, reason: :model_closed)
              session = for_model(model)
              return false unless session

              session.cancel(reason: reason, close_dialog: true, notify: false)
            end

            def cancel_all(reason: :model_closed)
              cancelled = false
              sessions_by_model_id.values.dup.each do |session|
                cancelled = true if session.cancel(reason: reason, close_dialog: true, notify: false)
              end
              cancelled
            end

            def reset!
              sessions_by_model_id.clear
            end
          end

          attr_reader :model
          attr_reader :indoor_model
          attr_reader :model_id
          attr_reader :progress
          attr_reader :state
          attr_reader :status
          attr_reader :cancel_reason
          attr_reader :generation
          attr_reader :workspace

          def initialize(model:, indoor_model:, progress:, state:, workspace: nil, on_cancel: nil, on_complete: nil, logger: nil)
            @model = model
            @indoor_model = indoor_model
            @model_id = model&.object_id
            @progress = progress
            @state = state
            @workspace = workspace
            @on_cancel = on_cancel
            @on_complete = on_complete
            @logger = logger || (defined?(IndoorCore::Logger) && IndoorCore::Logger)
            @status = :running
            @cancel_reason = nil
            @generation = 0
            @val_session = nil
            @cleanup_pending = false
            self.class.register(self)
          end

          def running?
            @status == :running
          end

          def result_ready?
            @status == :result_ready
          end

          def active?
            running? || result_ready?
          end

          def cancelled?
            @status == :cancelled || @status == :model_closed || @status == :model_changed
          end

          def completed?
            @status == :completed
          end

          def result_ready!
            return false unless running?

            @status = :result_ready
            true
          end

          def complete(reason: :closed)
            return false if completed?

            @status = :completed
            invalidate_callbacks!
            clear_dialog_callbacks
            cleanup_workspace
            self.class.unregister(self)
            @on_complete&.call(self, reason)
            true
          end

          def cancel(reason: :cancelled, close_dialog: true, terminate_process: true, notify: false)
            return false if completed? || cancelled?

            @status = reason == :model_closed ? :model_closed : :cancelled
            @cancel_reason = reason
            invalidate_callbacks!
            mark_state_cancelled(reason)
            terminated = terminate_process ? terminate_runner : true
            clear_dialog_callbacks
            notify_expired if notify
            close_progress_dialog if close_dialog
            if terminated
              cleanup_workspace
            else
              mark_cleanup_pending
              schedule_pending_cleanup
            end
            self.class.unregister(self)
            @on_cancel&.call(self, reason)
            true
          end

          def assign_val_session(session)
            @val_session = session
            @state[:val_session] = session if @state
          end

          def active_generation?(value)
            active? && @generation == value
          end

          def current_model_active?
            return false unless defined?(Sketchup)
            return false unless Sketchup.respond_to?(:active_model)

            Sketchup.active_model.equal?(@model)
          rescue StandardError
            false
          end

          def guard_report_action
            return false unless active?
            return true if current_model_active?

            cancel(reason: :model_changed, close_dialog: true, terminate_process: false, notify: true)
            false
          end

          def cleanup_workspace
            return false unless @workspace&.respond_to?(:cleanup)

            cleaned = @workspace.cleanup
            @cleanup_pending = false if cleaned
            cleaned
          rescue StandardError => e
            log("Validation workspace cleanup failed: #{e.class}: #{e.message}")
            false
          end

          def cleanup_pending?
            @cleanup_pending == true
          end

          private

          def invalidate_callbacks!
            @generation += 1
          end

          def mark_state_cancelled(reason)
            return unless @state

            @state[:cancelled] = true
            @state[:completed] = true
            @state[:val_running] = false
            @state[:temp_file_running] = false
            @state[:cancel_reason] = reason
          end

          def terminate_runner
            session = @val_session || @state&.[](:val_session)
            return true unless session&.respond_to?(:terminate)

            return false unless session.terminate(wait_ms: terminate_wait_ms)
            return session.finished? if session.respond_to?(:finished?)

            true
          rescue StandardError => e
            log("Validation process terminate skipped: #{e.class}: #{e.message}")
            false
          end

          def terminate_wait_ms
            if defined?(IndoorGmlConverter::Val3dityRunner::TERMINATE_WAIT_MS)
              IndoorGmlConverter::Val3dityRunner::TERMINATE_WAIT_MS
            else
              200
            end
          end

          def mark_cleanup_pending
            @cleanup_pending = true
            @state[:workspace_cleanup_pending] = true if @state
          end

          def schedule_pending_cleanup
            return unless defined?(UI) && UI.respond_to?(:start_timer)

            process_session = @val_session || @state&.[](:val_session)
            UI.start_timer(0.2, true) do
              unless cleanup_pending?
                next false
              end

              if process_session.nil? || !process_session.respond_to?(:finished?) || process_session.finished?
                finalize_process_session(process_session)
                next !cleanup_workspace
              end

              true
            rescue StandardError => e
              log("Validation pending workspace cleanup failed: #{e.class}: #{e.message}")
              false
            end
          rescue StandardError => e
            log("Validation pending workspace cleanup timer failed: #{e.class}: #{e.message}")
          end

          def finalize_process_session(process_session)
            return unless process_session

            process_session.join_reader if process_session.respond_to?(:join_reader)
            process_session.close if process_session.respond_to?(:close)
          rescue StandardError => e
            log("Validation process finalization failed: #{e.class}: #{e.message}")
          end

          def clear_dialog_callbacks
            @progress&.clear_callbacks if @progress&.respond_to?(:clear_callbacks)
          rescue StandardError => e
            log("Validation dialog callback cleanup failed: #{e.class}: #{e.message}")
          end

          def close_progress_dialog
            @progress&.close if @progress&.respond_to?(:close)
          rescue StandardError => e
            log("Validation dialog close failed: #{e.class}: #{e.message}")
          end

          def notify_expired
            return unless defined?(UI) && UI.respond_to?(:messagebox)

            UI.messagebox(EXPIRED_MESSAGE)
          rescue StandardError => e
            log("Validation expiration notice failed: #{e.class}: #{e.message}")
          end

          def log(message)
            @logger.puts("[IndoorGML] #{message}") if @logger&.respond_to?(:puts)
          end
        end
      end
    end
  end
end
