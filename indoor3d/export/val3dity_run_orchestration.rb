# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class Val3dityRunOrchestration
          def initialize(session:, progress:, progress_step:, callback:, register_session:, unregister_session:, drain_progress:, build_result:, error_result:, active: nil)
            @session = session
            @progress = progress
            @progress_step = progress_step
            @callback = callback
            @register_session = register_session
            @unregister_session = unregister_session
            @drain_progress = drain_progress
            @build_result = build_result
            @error_result = error_result
            @active = active || proc { true }
            @completed = false
          end

          def start
            @register_session.call(@session)
            start_progress_timer
            start_completion_timer
            @session
          rescue StandardError => e
            cleanup_session
            @callback.call(@error_result.call(e))
          end

          private

          def start_progress_timer
            UI.start_timer(0.1, true) do
              next false unless active?
              next false if @completed

              @drain_progress.call(@session, @progress, @progress_step)
              true
            end
          end

          def start_completion_timer
            UI.start_timer(0.2, true) do
              next false unless active?
              next false if @completed

              begin
                finished = @session.finished?
              rescue StandardError => e
                finish_with_error(e)
                next false
              end

              next true unless finished

              finish_session
              false
            end
          end

          def finish_with_error(error)
            cleanup_session
            @callback.call(@error_result.call(error))
          end

          def finish_session
            result = nil
            exit_code = nil
            build_report_later = false
            begin
              unless active?
                cleanup_session
                return
              end

              if @session.terminated?
                result = @error_result.call(RuntimeError.new('val3dity validation was canceled.'))
              else
                reader_finished = @session.join_reader
                raise 'val3dity output reader did not finish.' if reader_finished == false

                @drain_progress.call(@session, @progress, @progress_step)

                @progress&.complete(@progress_step)
                exit_code = @session.exit_code
                build_report_later = true
              end
            rescue StandardError => e
              result = @error_result.call(e)
            ensure
              cleanup_session unless @completed
            end

            if build_report_later
              start_report_timer(exit_code)
            else
              @callback.call(result) if result
            end
          end

          def start_report_timer(exit_code)
            UI.start_timer(0.05, false) do
              next false unless active?

              result = nil
              begin
                result = @build_result.call(exit_code)
              rescue StandardError => e
                result = @error_result.call(e)
              end

              @callback.call(result)
              false
            end
          end

          def active?
            @active.call == true
          rescue StandardError
            false
          end

          def cleanup_session
            return if @completed

            @session.close
            @unregister_session.call(@session)
            @completed = true
          end
        end

      end
    end
  end
end
