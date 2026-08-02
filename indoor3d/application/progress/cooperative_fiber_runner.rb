# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class CooperativeFiberRunner
          HEARTBEAT_INTERVAL = 0.25

          def initialize(
            model:,
            logger: IndoorCore::Logger,
            timer_start: nil,
            timer_stop: nil,
            heartbeat_interval: HEARTBEAT_INTERVAL
          )
            @model = model
            @logger = logger
            @timer_start = timer_start || proc do |delay, repeat, &block|
              UI.start_timer(delay, repeat, &block)
            end
            @timer_stop = timer_stop || proc { |timer_id| UI.stop_timer(timer_id) }
            @heartbeat_interval = [heartbeat_interval.to_f, 0.05].max
            @fiber = nil
            @heartbeat_timer_id = nil
            @resume_timer_id = nil
            @active = false
            @closed = false
          end

          def start(&work)
            raise ArgumentError, 'work block is required' unless work
            return false if active?

            @active = true
            @closed = false
            @fiber = Fiber.new do
              work.call(method(:yield_control))
            ensure
              finish
            end
            start_heartbeat
            schedule_resume
            true
          rescue StandardError => e
            log_error('start', e)
            finish
            false
          end

          def active?
            @active == true && !@closed
          end

          def close
            return false if @closed

            finish
            true
          end

          private

          def yield_control
            Fiber.yield
          end

          def schedule_resume
            return false unless active?

            @resume_timer_id = @timer_start.call(0.0, false) do
              @resume_timer_id = nil
              resume_once
            end
            true
          end

          def resume_once
            return false unless active?

            @fiber.resume
            schedule_resume if active? && @fiber&.alive?
            true
          rescue FiberError, StandardError => e
            log_error('resume', e)
            finish
            false
          end

          def start_heartbeat
            @heartbeat_timer_id = @timer_start.call(@heartbeat_interval, true) do
              heartbeat
            end
          end

          def heartbeat
            return false unless active?

            view = @model&.active_view
            return false unless view

            if view.respond_to?(:invalidate)
              view.invalidate
            elsif view.respond_to?(:refresh)
              view.refresh
            end
            true
          rescue StandardError => e
            log_error('heartbeat', e)
            false
          end

          def finish
            return false if @closed

            @active = false
            @closed = true
            stop_timer(@heartbeat_timer_id)
            stop_timer(@resume_timer_id)
            @heartbeat_timer_id = nil
            @resume_timer_id = nil
            @fiber = nil
            true
          end

          def stop_timer(timer_id)
            return unless timer_id

            @timer_stop.call(timer_id)
          rescue StandardError => e
            log_error('timer stop', e)
            nil
          end

          def log_error(context, error)
            @logger.puts(
              "[IndoorGML] Cooperative progress #{context} failed: #{error.class}: #{error.message}"
            )
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
