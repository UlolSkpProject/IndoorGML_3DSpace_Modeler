# frozen_string_literal: true

require 'fiddle'

require_relative 'val3dity_output_parser'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class Val3dityProcessAdapter
          CREATE_NO_WINDOW        = 0x08000000
          EXTENDED_STARTUPINFO_PRESENT = 0x00080000
          PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x00020002
          STARTF_USESTDHANDLES    = 0x00000100
          HANDLE_FLAG_INHERIT     = 0x00000001
          STARTUPINFO_SIZE        = 104
          STARTUPINFOEX_SIZE      = STARTUPINFO_SIZE + Fiddle::SIZEOF_VOIDP
          WAIT_OBJECT_0           = 0
          WAIT_TIMEOUT            = 258
          WAIT_FAILED             = 0xFFFFFFFF
          STILL_ACTIVE            = 259
          STDOUT_READ_BUFFER_SIZE = 4096
          TERMINATE_EXIT_CODE     = 1
          TERMINATE_WAIT_MS       = 200

          attr_reader :exit_code

          def initialize(args:, current_dir:)
            @args = args
            @current_dir = current_dir
            @process_handle = 0
            @thread_handle = 0
            @process_id = nil
            @stdout_read = 0
            @stdout_write = 0
            @reader_thread = nil
            @progress_queue = Queue.new
            @finished = false
            @output_finished = false
            @exit_code = nil
            @terminated = false
            @closed = false
          end

          def start(total_states:, total_transitions:)
            @stdout_read, @stdout_write = create_stdout_pipe

            startup_context = build_startup_context(@stdout_write)
            startup_info = startup_context[:startup_info]
            process_info = [0, 0, 0, 0].pack('Q<Q<L<L<')

            command = wide_string(@args.map { |arg| command_quote(arg) }.join(' '))
            current_dir = wide_string(@current_dir)

            created = create_process_w.call(
              0, command, 0, 0,
              1,
              CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
              0, current_dir,
              startup_info, process_info
            )
            raise "CreateProcessW failed: #{Fiddle.last_error}" if created == 0

            @process_handle, @thread_handle, @process_id = process_info.unpack('Q<Q<L<')

            close_handle.call(@stdout_write)
            @stdout_write = 0

            start_reader_thread(total_states: total_states, total_transitions: total_transitions)
          ensure
            cleanup_startup_context(startup_context) if defined?(startup_context)
          end

          def finished?
            return true if @finished

            result = wait_for_single_object.call(@process_handle, 0)
            case result
            when WAIT_TIMEOUT
              false
            when WAIT_OBJECT_0
              finish_from_exit_code(get_process_exit_code)
            when WAIT_FAILED
              raise "WaitForSingleObject failed: #{Fiddle.last_error}"
            else
              finish_from_unexpected_wait_result(result)
            end
          end

          def pop_progress
            @progress_queue.pop(true)
          rescue ThreadError
            nil
          end

          def join_reader(timeout = 1.0)
            @reader_thread&.join(timeout)
            @output_finished == true
          end

          def terminated?
            @terminated == true
          end

          def close
            return if @closed

            close_handle.call(@stdout_write) if @stdout_write.to_i.positive?
            close_handle.call(@stdout_read) if @stdout_read.to_i.positive?
            close_handle.call(@thread_handle) if @thread_handle.to_i.positive?
            close_handle.call(@process_handle) if @process_handle.to_i.positive?

            @stdout_write = @stdout_read = @thread_handle = @process_handle = 0
            @closed = true
          end

          def terminate(wait_ms: TERMINATE_WAIT_MS)
            return true if @closed
            return close_and_report_finished if @process_handle.to_i <= 0

            if finished?
              @terminated = true
              join_reader if wait_ms.to_i.positive?
              close
              return true
            end

            ok = terminate_process.call(@process_handle, TERMINATE_EXIT_CODE)
            if ok == 0
              IndoorCore::Logger.puts "[IndoorGML] TerminateProcess failed: #{Fiddle.last_error}"
              return false
            end

            @terminated = true
            wait_result = wait_ms.to_i.positive? ? wait_for_single_object.call(@process_handle, wait_ms.to_i) : WAIT_TIMEOUT
            if wait_result == WAIT_TIMEOUT && wait_ms.to_i.positive?
              kill_process_tree
              wait_result = wait_for_single_object.call(@process_handle, wait_ms.to_i)
            end

            return false if wait_result == WAIT_TIMEOUT
            raise "WaitForSingleObject failed after TerminateProcess: #{Fiddle.last_error}" if wait_result == WAIT_FAILED

            if wait_result == WAIT_OBJECT_0
              finish_from_exit_code(get_process_exit_code)
            else
              return false unless finish_from_unexpected_wait_result(wait_result)
            end

            join_reader if wait_ms.to_i.positive?
            close
            true
          rescue StandardError => e
            @progress_queue << {
              percent: nil,
              phase: 'val3dity process',
              message: "terminate failed: #{e.class}: #{e.message}",
              current: nil
            }
            false
          end

          private

          def create_stdout_pipe
            sa = [24, 0, 1].pack('L<x4Q<L<')
            read_ptr = [0].pack('Q<')
            write_ptr = [0].pack('Q<')

            ok = create_pipe.call(read_ptr, write_ptr, sa, 0)
            raise "CreatePipe failed: #{Fiddle.last_error}" if ok == 0

            read_handle = read_ptr.unpack1('Q<')
            write_handle = write_ptr.unpack1('Q<')

            ok = set_handle_information.call(read_handle, HANDLE_FLAG_INHERIT, 0)
            raise "SetHandleInformation failed: #{Fiddle.last_error}" if ok == 0

            [read_handle, write_handle]
          end

          def build_startup_context(stdout_write)
            # Keep handle_list alive until CreateProcessW returns; the attribute
            # list may reference it while creating the child process.
            handle_list = pack_handle_list([stdout_write])
            attribute_list = build_handle_attribute_list(handle_list)
            {
              attribute_list: attribute_list,
              handle_list: handle_list,
              startup_info: build_startup_info_ex(stdout_write, attribute_list)
            }
          end

          def build_handle_attribute_list(handle_list)
            size_ptr = pack_size_t(0)
            initialize_proc_thread_attribute_list.call(0, 1, 0, size_ptr)
            size = unpack_size_t(size_ptr)
            raise "InitializeProcThreadAttributeList size query failed: #{Fiddle.last_error}" if size.to_i <= 0

            attribute_list = "\0".b * size
            initialized = false
            ok = initialize_proc_thread_attribute_list.call(attribute_list, 1, 0, size_ptr)
            raise "InitializeProcThreadAttributeList failed: #{Fiddle.last_error}" if ok == 0

            initialized = true
            ok = update_proc_thread_attribute.call(
              attribute_list,
              0,
              PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
              handle_list,
              handle_list.bytesize,
              0,
              0
            )
            raise "UpdateProcThreadAttribute failed: #{Fiddle.last_error}" if ok == 0

            attribute_list
          rescue StandardError
            delete_proc_thread_attribute_list.call(attribute_list) if initialized
            raise
          end

          def cleanup_startup_context(startup_context)
            attribute_list = startup_context && startup_context[:attribute_list]
            delete_proc_thread_attribute_list.call(attribute_list) if attribute_list
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Startup attribute cleanup failed: #{e.class}: #{e.message}"
          end

          def build_startup_info_ex(stdout_write, attribute_list)
            [
              STARTUPINFOEX_SIZE,
              0,
              0,
              0,
              0, 0, 0, 0,
              0, 0,
              0,
              STARTF_USESTDHANDLES,
              0,
              0,
              0,
              0,
              stdout_write,
              stdout_write,
              Fiddle::Pointer[attribute_list].to_i
            ].pack('L<x4Q<Q<Q<L<L<L<L<L<L<L<L<S<Sx4Q<Q<Q<Q<Q<')
          end

          def pack_handle_list(handles)
            unique_handles = handles.compact.map(&:to_i).uniq
            if Fiddle::SIZEOF_VOIDP == 8
              unique_handles.pack('Q<*')
            else
              unique_handles.pack('L<*')
            end
          end

          def pack_size_t(value)
            if Fiddle::SIZEOF_SIZE_T == 8
              [value].pack('Q<')
            else
              [value].pack('L<')
            end
          end

          def unpack_size_t(buffer)
            if Fiddle::SIZEOF_SIZE_T == 8
              buffer.unpack1('Q<')
            else
              buffer.unpack1('L<')
            end
          end

          def start_reader_thread(total_states:, total_transitions:)
            parser = Val3dityOutputParser.new(
              @progress_queue,
              total_states: total_states,
              total_transitions: total_transitions
            )

            @reader_thread = Thread.new do
              begin
                read_process_output { |chunk| parser.feed(chunk) }
                parser.finish
              rescue StandardError => e
                @progress_queue << {
                  percent: nil,
                  phase: 'val3dity output',
                  message: "stdout read failed: #{e.class}: #{e.message}",
                  current: nil
                }
              ensure
                @output_finished = true
              end
            end
          end

          def finish_from_exit_code(code)
            raise 'val3dity process is still active.' if code == STILL_ACTIVE

            @exit_code = code
            @finished = true
            true
          end

          def finish_from_unexpected_wait_result(result)
            code = get_process_exit_code
            return finish_from_exit_code(code) unless code == STILL_ACTIVE

            IndoorCore::Logger.puts "[IndoorGML] WaitForSingleObject returned #{result}; val3dity process is still active"
            false
          rescue StandardError => e
            raise "Unexpected WaitForSingleObject result #{result}: #{e.message}"
          end

          def close_and_report_finished
            close
            true
          end

          def read_process_output
            buffer = "\0" * STDOUT_READ_BUFFER_SIZE
            bytes_read_ptr = [0].pack('L<')

            loop do
              bytes_read_ptr[0, 4] = [0].pack('L<')

              ok = read_file.call(@stdout_read, buffer, STDOUT_READ_BUFFER_SIZE, bytes_read_ptr, 0)
              bytes_read = bytes_read_ptr.unpack1('L<')
              break if ok == 0 || bytes_read == 0

              chunk = buffer.byteslice(0, bytes_read)
              yield chunk if chunk && !chunk.empty?
            end
          end

          def get_process_exit_code
            ptr = [0].pack('L<')
            ok = get_exit_code_process.call(@process_handle, ptr)
            raise "GetExitCodeProcess failed: #{Fiddle.last_error}" if ok == 0

            ptr.unpack1('L<')
          end

          def kernel32
            @kernel32 ||= Fiddle.dlopen('kernel32')
          end

          def create_pipe
            @create_pipe ||= Fiddle::Function.new(
              kernel32['CreatePipe'],
              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
              Fiddle::TYPE_INT
            )
          end

          def set_handle_information
            @set_handle_information ||= Fiddle::Function.new(
              kernel32['SetHandleInformation'],
              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG],
              Fiddle::TYPE_INT
            )
          end

          def initialize_proc_thread_attribute_list
            @initialize_proc_thread_attribute_list ||= Fiddle::Function.new(
              kernel32['InitializeProcThreadAttributeList'],
              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP],
              Fiddle::TYPE_INT
            )
          end

          def update_proc_thread_attribute
            @update_proc_thread_attribute ||= Fiddle::Function.new(
              kernel32['UpdateProcThreadAttribute'],
              [
                Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_UINTPTR_T,
                Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T,
                Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP
              ],
              Fiddle::TYPE_INT
            )
          end

          def delete_proc_thread_attribute_list
            @delete_proc_thread_attribute_list ||= Fiddle::Function.new(
              kernel32['DeleteProcThreadAttributeList'],
              [Fiddle::TYPE_VOIDP],
              Fiddle::TYPE_VOID
            )
          end

          def create_process_w
            @create_process_w ||= Fiddle::Function.new(
              kernel32['CreateProcessW'],
              [
                Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                Fiddle::TYPE_INT, Fiddle::TYPE_LONG,
                Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP
              ],
              Fiddle::TYPE_INT
            )
          end

          def read_file
            @read_file ||= Fiddle::Function.new(
              kernel32['ReadFile'],
              [
                Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG,
                Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP
              ],
              Fiddle::TYPE_INT
            )
          end

          def wait_for_single_object
            @wait_for_single_object ||= Fiddle::Function.new(
              kernel32['WaitForSingleObject'],
              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
              Fiddle::TYPE_LONG
            )
          end

          def get_exit_code_process
            @get_exit_code_process ||= Fiddle::Function.new(
              kernel32['GetExitCodeProcess'],
              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
              Fiddle::TYPE_INT
            )
          end

          def close_handle
            @close_handle ||= Fiddle::Function.new(
              kernel32['CloseHandle'],
              [Fiddle::TYPE_VOIDP],
              Fiddle::TYPE_INT
            )
          end

          def terminate_process
            @terminate_process ||= Fiddle::Function.new(
              kernel32['TerminateProcess'],
              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
              Fiddle::TYPE_INT
            )
          end

          def kill_process_tree
            return unless @process_id.to_i.positive?

            system('taskkill', '/PID', @process_id.to_s, '/T', '/F')
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] taskkill fallback failed: #{e.class}: #{e.message}"
          end

          def command_quote(value)
            %("#{value.to_s.gsub('"', '\"')}")
          end

          def wide_string(value)
            "#{value}\x00".encode('UTF-16LE')
          end
        end

      end
    end
  end
end
