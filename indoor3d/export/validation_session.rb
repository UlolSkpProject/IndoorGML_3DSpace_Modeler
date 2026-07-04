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

            def cancel_except_model(model, reason: :model_changed)
              keep_id = model&.object_id
              cancelled = false
              sessions_by_model_id.values.dup.each do |session|
                next if session.model_id == keep_id

                cancelled = true if session.cancel(reason: reason, close_dialog: true, notify: false)
              end
              cancelled
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

          def initialize(model:, indoor_model:, progress:, state:, on_cancel: nil, on_complete: nil, logger: nil)
            @model = model
            @indoor_model = indoor_model
            @model_id = model&.object_id
            @progress = progress
            @state = state
            @on_cancel = on_cancel
            @on_complete = on_complete
            @logger = logger || (defined?(IndoorCore::Logger) && IndoorCore::Logger)
            @status = :running
            @cancel_reason = nil
            @generation = 0
            @val_session = nil
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
            terminate_runner if terminate_process
            clear_dialog_callbacks
            notify_expired if notify
            close_progress_dialog if close_dialog
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
            return unless session&.respond_to?(:terminate)

            session.terminate(wait_ms: 0)
          rescue StandardError => e
            log("Validation process terminate skipped: #{e.class}: #{e.message}")
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
