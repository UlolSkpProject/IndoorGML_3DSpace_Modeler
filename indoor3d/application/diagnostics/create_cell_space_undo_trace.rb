# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Diagnostics
        module CreateCellSpaceUndoTrace
          TRACE_FILENAME = 'IndoorGML_Create_CellSpace_Undo_Trace.log'
          POST_COMMAND_TRACE_SECONDS = 2.0
          MAX_EVENT_COUNT = 100_000

          PROPERTY_METHODS = %i[
            set_attribute delete_attribute []=
            locked= name= material= back_material=
            layer= tag= visible= hidden= transformation=
          ].freeze
          ACTIVE_PATH_METHODS = %i[active_path= close_active].freeze
          OPERATION_METHODS = %i[start_operation commit_operation abort_operation].freeze
          WATCHED_METHODS = (PROPERTY_METHODS + ACTIVE_PATH_METHODS + OPERATION_METHODS).freeze

          class << self
            attr_writer :output_path

            def active?
              @active == true
            end

            def start
              finish(reason: :restarted) if active?

              @generation = @generation.to_i + 1
              @active = true
              @recording = false
              @started_at = monotonic_time
              @event_count = 0
              @native_operation_depth = 0
              @operation_stack = []
              @outside_property_events = []
              @last_native_close = nil
              open_log
              write_line('=== IndoorGML Create CellSpace Undo Trace ===')
              write_line("started_at=#{Time.now}")
              write_line("ruby=#{RUBY_VERSION}")
              write_line("output=#{output_path}")
              write_line('classification: IN_OPERATION means a native SketchUp operation is open; OUTSIDE_OPERATION is a candidate for the extra Properties Undo item.')
              install_tracepoint
              mark(:trace_started)
              log_console("Undo trace started: #{output_path}")
              true
            rescue StandardError => e
              @active = false
              close_log
              log_console("Undo trace start failed: #{e.class}: #{e.message}")
              false
            end

            def mark(label, payload = nil)
              return false unless active?

              suffix = payload.nil? ? '' : " payload=#{safe_value(payload)}"
              write_line("#{timestamp} MARK #{label}#{suffix}")
              true
            rescue StandardError
              false
            end

            def operation_enter(name, options = nil)
              return unless active?

              @operation_stack << name.to_s
              write_line(
                "#{timestamp} WRAPPER_ENTER name=#{name.inspect} " \
                "depth=#{@operation_stack.length} options=#{safe_value(options || {})}"
              )
            rescue StandardError
              nil
            end

            def operation_exit(name)
              return unless active?

              write_line(
                "#{timestamp} WRAPPER_EXIT name=#{name.inspect} " \
                "depth=#{@operation_stack.length}"
              )
              @operation_stack.pop
            rescue StandardError
              @operation_stack = []
              nil
            end

            def schedule_finish
              return false unless active?

              generation = @generation
              if defined?(UI) && UI.respond_to?(:start_timer)
                UI.start_timer(POST_COMMAND_TRACE_SECONDS, false) do
                  finish(reason: :post_command_timeout) if @generation == generation
                end
              else
                finish(reason: :no_ui_timer)
              end
              true
            rescue StandardError => e
              write_line("#{timestamp} SCHEDULE_FINISH_ERROR #{e.class}: #{e.message}")
              finish(reason: :schedule_failed)
              false
            end

            def finish(reason: :manual)
              return false unless active?

              mark(:trace_finishing, reason: reason)
              disable_tracepoint
              write_summary(reason)
              @active = false
              close_log
              log_console(
                "Undo trace finished: #{output_path} " \
                "(outside property writes=#{@outside_property_events.length})"
              )
              true
            rescue StandardError => e
              @active = false
              disable_tracepoint
              close_log
              log_console("Undo trace finish failed: #{e.class}: #{e.message}")
              false
            end

            def output_path
              return @output_path unless @output_path.to_s.empty?

              base = ENV['TEMP'].to_s
              base = ENV['TMP'].to_s if base.empty?
              base = Dir.tmpdir if base.empty?
              File.join(base, TRACE_FILENAME)
            end

            private

            def install_tracepoint
              @tracepoint = TracePoint.new(:call, :c_call, :return, :c_return) do |trace|
                handle_tracepoint(trace)
              end
              @tracepoint.enable
            end

            def disable_tracepoint
              @tracepoint&.disable
              @tracepoint = nil
            rescue StandardError
              @tracepoint = nil
            end

            def handle_tracepoint(trace)
              return unless active?
              return if @recording
              return unless WATCHED_METHODS.include?(trace.method_id)
              return unless relevant_receiver?(trace.self, trace.method_id)

              @recording = true
              case trace.event
              when :call, :c_call
                handle_call_event(trace)
              when :return, :c_return
                handle_return_event(trace)
              end
            rescue StandardError => e
              write_line("#{timestamp} TRACE_CALLBACK_ERROR #{e.class}: #{e.message}")
            ensure
              @recording = false
            end

            def handle_call_event(trace)
              method_id = trace.method_id
              case method_id
              when :start_operation
                record_trace_event(trace, kind: 'OPERATION_CALL', classification: operation_classification)
                @native_operation_depth += 1
              when :commit_operation, :abort_operation
                record_trace_event(trace, kind: 'OPERATION_CALL', classification: operation_classification)
              else
                classification = operation_classification
                record_trace_event(trace, kind: event_kind(method_id), classification: classification)
                remember_outside_property_event(trace) if classification == 'OUTSIDE_OPERATION' && property_method?(method_id)
              end
            end

            def handle_return_event(trace)
              method_id = trace.method_id
              case method_id
              when :start_operation
                if trace.return_value == false
                  @native_operation_depth = [@native_operation_depth - 1, 0].max
                end
                record_trace_event(trace, kind: 'OPERATION_RETURN', classification: operation_classification)
              when :commit_operation, :abort_operation
                @native_operation_depth = [@native_operation_depth - 1, 0].max
                @last_native_close = {
                  method: method_id,
                  at: monotonic_time,
                  return_value: trace.return_value
                }
                record_trace_event(trace, kind: 'OPERATION_RETURN', classification: operation_classification)
              end
            end

            def record_trace_event(trace, kind:, classification:)
              @event_count += 1
              return if @event_count > MAX_EVENT_COUNT

              line = [
                timestamp,
                kind,
                classification,
                "event=#{trace.event}",
                "method=#{trace.method_id}",
                "defined_class=#{safe_class_name(trace.defined_class)}",
                "receiver=#{receiver_label(trace.self)}",
                "native_depth=#{@native_operation_depth}",
                "wrapper=#{@operation_stack.last.inspect}",
                last_close_label
              ].compact.join(' ')
              write_line(line)
              caller_lines(trace).each { |location| write_line("  at #{location}") }
            end

            def remember_outside_property_event(trace)
              @outside_property_events << {
                elapsed: monotonic_time - @started_at,
                method: trace.method_id,
                receiver: receiver_label(trace.self),
                caller: caller_lines(trace).first
              }
            rescue StandardError
              nil
            end

            def write_summary(reason)
              write_line('=== SUMMARY ===')
              write_line("reason=#{reason}")
              write_line("events=#{@event_count}")
              write_line("outside_property_writes=#{@outside_property_events.length}")
              @outside_property_events.each_with_index do |event, index|
                write_line(
                  format(
                    'outside[%d] +%.6fs method=%s receiver=%s caller=%s',
                    index + 1,
                    event[:elapsed],
                    event[:method],
                    event[:receiver],
                    event[:caller]
                  )
                )
              end
              write_line('=== END ===')
            end

            def relevant_receiver?(receiver, method_id)
              class_name = receiver.class.name.to_s
              return true if class_name.start_with?('Sketchup::')
              return true if OPERATION_METHODS.include?(method_id) && receiver.respond_to?(:start_operation)

              false
            rescue StandardError
              false
            end

            def event_kind(method_id)
              ACTIVE_PATH_METHODS.include?(method_id) ? 'ACTIVE_PATH_WRITE' : 'PROPERTY_WRITE'
            end

            def property_method?(method_id)
              PROPERTY_METHODS.include?(method_id)
            end

            def operation_classification
              @native_operation_depth.positive? ? 'IN_OPERATION' : 'OUTSIDE_OPERATION'
            end

            def last_close_label
              return nil unless @last_native_close

              elapsed = monotonic_time - @last_native_close[:at]
              format(
                'last_close=%s/%.6fs/return=%s',
                @last_native_close[:method],
                elapsed,
                safe_value(@last_native_close[:return_value])
              )
            end

            def caller_lines(trace)
              lines = []
              trace_path = trace.path.to_s
              unless trace_path.empty?
                lines << "#{trace_path}:#{trace.lineno}:in `#{trace.method_id}'"
              end

              locations = caller_locations(4, 50).reject do |location|
                normalized = location.path.to_s.tr('\\', '/')
                normalized.end_with?('/application/diagnostics/create_cell_space_undo_trace.rb')
              end
              plugin_locations = locations.select do |location|
                path = location.path.to_s.tr('\\', '/')
                path.include?('/IndoorGML_3DSpace_Modeler/') || path.include?('/indoor3d/')
              end
              selected = plugin_locations.empty? ? locations.first(8) : plugin_locations.first(12)
              lines.concat(selected.map do |location|
                "#{location.path}:#{location.lineno}:in `#{location.base_label}'"
              end)
              lines.uniq
            rescue StandardError
              []
            end

            def receiver_label(receiver)
              details = ["object_id=#{receiver.object_id}"]
              if receiver.respond_to?(:entityID)
                entity_id = receiver.entityID
                details << "entityID=#{entity_id}" unless entity_id.nil?
              end
              if receiver.respond_to?(:persistent_id)
                persistent_id = receiver.persistent_id
                details << "persistent_id=#{persistent_id}" unless persistent_id.nil?
              end
              if receiver.respond_to?(:name)
                name = receiver.name
                details << "name=#{name.inspect}" unless name.to_s.empty?
              end
              "#{safe_class_name(receiver.class)}(#{details.join(',')})"
            rescue StandardError
              "#{safe_class_name(receiver.class)}(object_id=#{receiver.object_id})"
            end

            def safe_class_name(value)
              value.respond_to?(:name) && !value.name.to_s.empty? ? value.name.to_s : value.to_s
            rescue StandardError
              value.to_s
            end

            def safe_value(value)
              value.inspect
            rescue StandardError
              '<uninspectable>'
            end

            def timestamp
              format('[+%.6fs]', monotonic_time - @started_at)
            end

            def monotonic_time
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end

            def open_log
              path = output_path
              FileUtils.mkdir_p(File.dirname(path))
              @io = File.open(path, 'w:UTF-8')
              @io.sync = true
            end

            def write_line(line)
              @io&.puts(line)
            rescue StandardError
              nil
            end

            def close_log
              @io&.close unless @io&.closed?
              @io = nil
            rescue StandardError
              @io = nil
            end

            def log_console(message)
              if defined?(IndoorCore::Logger) && IndoorCore::Logger.respond_to?(:puts)
                IndoorCore::Logger.puts("[IndoorGML][UndoTrace] #{message}")
              else
                puts("[IndoorGML][UndoTrace] #{message}")
              end
            rescue StandardError
              nil
            end
          end
        end

        module IndoorModelOperationTrace
          def with_indoor_model_operation(name, **options, &block)
            CreateCellSpaceUndoTrace.operation_enter(name, options)
            super
          ensure
            CreateCellSpaceUndoTrace.operation_exit(name)
          end
        end

        module CommandDispatcherCreateCellSpaceUndoTrace
          def convert_selected_solid_groups_to_cell_spaces(*arguments, **keywords, &block)
            started = CreateCellSpaceUndoTrace.start
            CreateCellSpaceUndoTrace.mark(:command_enter) if started
            result = super
            CreateCellSpaceUndoTrace.mark(:command_return, result_class: result.class.name) if started
            result
          rescue StandardError => e
            CreateCellSpaceUndoTrace.mark(
              :command_error,
              error_class: e.class.name,
              message: e.message
            ) if started
            raise
          ensure
            CreateCellSpaceUndoTrace.schedule_finish if started
          end
        end
      end

      if defined?(IndoorModel)
        IndoorModel.prepend(
          Diagnostics::IndoorModelOperationTrace
        ) unless IndoorModel.ancestors.include?(
          Diagnostics::IndoorModelOperationTrace
        )
      end

      if defined?(CommandDispatcher)
        CommandDispatcher.prepend(
          Diagnostics::CommandDispatcherCreateCellSpaceUndoTrace
        ) unless CommandDispatcher.ancestors.include?(
          Diagnostics::CommandDispatcherCreateCellSpaceUndoTrace
        )
      end
    end
  end
end
