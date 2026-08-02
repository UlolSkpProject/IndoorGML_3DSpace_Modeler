# frozen_string_literal: true

require_relative 'null_progress_renderer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class ProductionProgressSession
          class StateError < StandardError; end

          TERMINAL_STATUSES = %i[completed cancelled failed].freeze

          attr_reader :id

          def initialize(
            title:,
            total:,
            renderer: NullProgressRenderer.new,
            clock: nil,
            cancellable: false,
            metadata: {}
          )
            @id = "progress-#{object_id}"
            @title = title.to_s
            @total = normalize_total(total)
            @renderer = renderer || NullProgressRenderer.new
            @clock = clock || proc { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            @default_cancellable = cancellable == true
            @metadata = deep_copy(metadata)
            @status = :idle
            @completed = 0
            @message = ''
            @started_at = nil
            @finished_at = nil
            @closed = false
            @cancel_requested = false
            @cancellable = false
            @stage = nil
            @stages = []
            @telemetry = {}
            @error = nil
            @renderer_error_count = 0
          end

          def start(message: nil)
            ensure_status!(:idle)

            @status = :running
            @started_at = now
            @message = message.to_s unless message.nil?
            @cancellable = @default_cancellable
            publish(:show)
            snapshot
          end

          def update(completed: nil, message: nil, telemetry: nil)
            ensure_running!

            @completed = normalize_completed(completed, @total) unless completed.nil?
            @message = message.to_s unless message.nil?
            merge_telemetry!(@telemetry, telemetry)
            publish(:update)
            snapshot
          end

          def start_stage(name, total:, message: nil, cancellable: nil, metadata: {})
            ensure_running!
            archive_terminal_stage!
            if @stage && @stage[:status] == :running
              raise StateError, "Cannot start stage #{name.inspect} while #{@stage[:name].inspect} is running"
            end

            started_at = now
            @stage = {
              name: name.to_s,
              status: :running,
              total: normalize_total(total),
              completed: 0,
              message: message.nil? ? '' : message.to_s,
              started_at: started_at,
              finished_at: nil,
              cancellable: cancellable.nil? ? @default_cancellable : cancellable == true,
              metadata: deep_copy(metadata),
              telemetry: {}
            }
            @cancellable = @stage[:cancellable]
            @message = @stage[:message] unless @stage[:message].empty?
            publish(:update)
            snapshot
          end

          def update_stage(completed:, message: nil, telemetry: nil)
            ensure_running!
            ensure_stage_running!

            @stage[:completed] = normalize_completed(completed, @stage[:total])
            @stage[:message] = message.to_s unless message.nil?
            @message = @stage[:message] unless message.nil?
            merge_telemetry!(@stage[:telemetry], telemetry)
            publish(:update)
            snapshot
          end

          def finish_stage(message: nil, telemetry: nil)
            ensure_running!
            ensure_stage_running!

            @stage[:completed] = @stage[:total]
            @stage[:status] = :completed
            @stage[:finished_at] = now
            @stage[:message] = message.to_s unless message.nil?
            @message = @stage[:message] unless message.nil?
            merge_telemetry!(@stage[:telemetry], telemetry)
            @cancellable = @default_cancellable
            publish(:update)
            snapshot
          end

          def set_cancellable(value)
            ensure_running!

            @cancellable = value == true
            @stage[:cancellable] = @cancellable if @stage && @stage[:status] == :running
            publish(:update)
            @cancellable
          end

          def request_cancel
            return false unless @status == :running
            return false unless @cancellable

            @cancel_requested = true
            publish(:update)
            true
          end

          def complete(message: nil, telemetry: nil)
            finish_terminal!(:completed, message: message, telemetry: telemetry)
          end

          def cancel(message: nil, telemetry: nil)
            finish_terminal!(:cancelled, message: message, telemetry: telemetry)
          end

          def fail(error, message: nil, telemetry: nil)
            ensure_running!

            @error = {
              class: error.respond_to?(:class) ? error.class.name.to_s : '',
              message: error.respond_to?(:message) ? error.message.to_s : error.to_s
            }
            finish_terminal!(:failed, message: message || @error[:message], telemetry: telemetry)
          end

          def close
            return false if @closed

            @closed = true
            safe_render(:hide, snapshot)
            safe_render(:close)
            true
          end

          def active?
            @status == :running
          end

          def terminal?
            TERMINAL_STATUSES.include?(@status)
          end

          def cancel_requested?
            @cancel_requested == true
          end

          def closed?
            @closed == true
          end

          def snapshot
            current_time = @finished_at || now
            data = {
              id: @id,
              title: @title,
              status: @status,
              active: active?,
              terminal: terminal?,
              closed: closed?,
              cancellable: @cancellable == true,
              cancel_requested: cancel_requested?,
              message: @message,
              total: @total,
              completed: @completed,
              percent: progress_percent(@completed, @total, complete: @status == :completed),
              elapsed: elapsed(@started_at, current_time),
              started_at: @started_at,
              finished_at: @finished_at,
              stage: stage_snapshot(current_time),
              stages: @stages.map { |stage| stage_snapshot_for(stage, current_time) },
              telemetry: deep_copy(@telemetry),
              metadata: deep_copy(@metadata),
              error: deep_copy(@error),
              renderer_error_count: @renderer_error_count
            }
            deep_freeze(data)
          end

          private

          def finish_terminal!(status, message:, telemetry:)
            ensure_running!

            finished_at = now
            if @stage && @stage[:status] == :running
              @stage[:status] = status == :completed ? :completed : status
              @stage[:completed] = @stage[:total] if status == :completed
              @stage[:finished_at] = finished_at
            end
            @completed = @total if status == :completed
            @status = status
            @finished_at = finished_at
            @message = message.to_s unless message.nil?
            @cancellable = false
            merge_telemetry!(@telemetry, telemetry)
            publish(:update)
            snapshot
          end

          def publish(method_name)
            safe_render(method_name, snapshot)
          end

          def safe_render(method_name, *args)
            return false unless @renderer.respond_to?(method_name)

            @renderer.public_send(method_name, *args)
            true
          rescue StandardError
            @renderer_error_count += 1
            false
          end

          def ensure_status!(expected)
            return if @status == expected

            raise StateError, "Expected #{expected}, got #{@status}"
          end

          def ensure_running!
            ensure_status!(:running)
          end

          def ensure_stage_running!
            return if @stage && @stage[:status] == :running

            raise StateError, 'No running progress stage'
          end

          def archive_terminal_stage!
            return unless @stage && @stage[:status] != :running

            @stages << deep_copy(@stage)
            @stage = nil
          end

          def stage_snapshot(current_time)
            return nil unless @stage

            stage_snapshot_for(@stage, current_time)
          end

          def stage_snapshot_for(stage, current_time)
            {
              name: stage[:name],
              status: stage[:status],
              total: stage[:total],
              completed: stage[:completed],
              percent: progress_percent(
                stage[:completed],
                stage[:total],
                complete: stage[:status] == :completed
              ),
              elapsed: elapsed(stage[:started_at], stage[:finished_at] || current_time),
              started_at: stage[:started_at],
              finished_at: stage[:finished_at],
              cancellable: stage[:cancellable] == true,
              message: stage[:message],
              telemetry: deep_copy(stage[:telemetry]),
              metadata: deep_copy(stage[:metadata])
            }
          end

          def progress_percent(completed, total, complete: false)
            return complete ? 100.0 : 0.0 unless total.positive?

            [[completed.fdiv(total) * 100.0, 0.0].max, 100.0].min
          end

          def elapsed(started_at, current_time)
            return 0.0 unless started_at

            [current_time.to_f - started_at.to_f, 0.0].max
          end

          def normalize_total(value)
            [value.to_i, 0].max
          end

          def normalize_completed(value, total)
            completed = [value.to_i, 0].max
            total.positive? ? [completed, total].min : completed
          end

          def merge_telemetry!(target, values)
            return target unless values

            values.to_h.each { |key, value| target[key.to_sym] = deep_copy(value) }
            target
          end

          def now
            @clock.call.to_f
          end

          def deep_copy(value)
            case value
            when Hash
              value.each_with_object({}) { |(key, item), copy| copy[key] = deep_copy(item) }
            when Array
              value.map { |item| deep_copy(item) }
            when String
              value.dup
            else
              value
            end
          end

          def deep_freeze(value)
            case value
            when Hash
              value.each do |key, item|
                deep_freeze(key)
                deep_freeze(item)
              end
            when Array
              value.each { |item| deep_freeze(item) }
            end
            value.freeze
          end
        end
      end
    end
  end
end
