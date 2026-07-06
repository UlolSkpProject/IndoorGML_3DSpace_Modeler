# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

require_relative '../indoor3d/validity/val3dity_process_adapter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityProcessAdapterTest < Minitest::Test
          def test_stdout_eof_does_not_mark_running_process_finished
            adapter = build_adapter(
              wait_result: Val3dityProcessAdapter::WAIT_TIMEOUT,
              exit_code: Val3dityProcessAdapter::STILL_ACTIVE
            )
            adapter.instance_variable_set(:@output_finished, true)

            refute adapter.finished?
            assert_nil adapter.exit_code
          end

          def test_signaled_process_preserves_non_zero_exit_code
            adapter = build_adapter(
              wait_result: Val3dityProcessAdapter::WAIT_OBJECT_0,
              exit_code: 7
            )

            assert adapter.finished?
            assert_equal 7, adapter.exit_code
          end

          def test_signaled_process_does_not_convert_still_active_to_success
            adapter = build_adapter(
              wait_result: Val3dityProcessAdapter::WAIT_OBJECT_0,
              exit_code: Val3dityProcessAdapter::STILL_ACTIVE
            )

            error = assert_raises(RuntimeError) { adapter.finished? }
            assert_match(/still active/, error.message)
          end

          def test_wait_failed_raises_process_adapter_error
            adapter = build_adapter(
              wait_result: Val3dityProcessAdapter::WAIT_FAILED,
              exit_code: nil
            )

            error = assert_raises(RuntimeError) { adapter.finished? }
            assert_match(/WaitForSingleObject failed/, error.message)
          end

          def test_terminate_timeout_keeps_process_open_for_later_polling
            wait = FakeWaitSequence.new([
              Val3dityProcessAdapter::WAIT_TIMEOUT,
              Val3dityProcessAdapter::WAIT_TIMEOUT,
              Val3dityProcessAdapter::WAIT_TIMEOUT
            ])
            adapter = build_adapter(
              wait_result: wait,
              exit_code: Val3dityProcessAdapter::STILL_ACTIVE,
              terminate_result: 1
            )

            refute adapter.terminate(wait_ms: 1)

            refute adapter.finished?
            refute adapter.closed?
          end

          def test_terminate_failure_keeps_process_open_for_later_polling
            adapter = build_adapter(
              wait_result: Val3dityProcessAdapter::WAIT_TIMEOUT,
              exit_code: Val3dityProcessAdapter::STILL_ACTIVE,
              terminate_result: 0
            )

            refute adapter.terminate(wait_ms: 1)

            refute adapter.finished?
            refute adapter.closed?
          end

          def test_confirmed_terminate_finishes_and_closes_process
            wait = FakeWaitSequence.new([
              Val3dityProcessAdapter::WAIT_TIMEOUT,
              Val3dityProcessAdapter::WAIT_OBJECT_0
            ])
            adapter = build_adapter(
              wait_result: wait,
              exit_code: Val3dityProcessAdapter::TERMINATE_EXIT_CODE,
              terminate_result: 1
            )

            assert adapter.terminate(wait_ms: 1)
            assert adapter.finished?
            assert adapter.closed?
            assert_equal Val3dityProcessAdapter::TERMINATE_EXIT_CODE, adapter.exit_code
          end

          def test_start_whitelists_only_stdout_write_handle_for_inheritance
            adapter = Val3dityProcessAdapter.new(args: ['val3dity.exe'], current_dir: Dir.tmpdir)
            events = []
            attribute_list_seen = nil
            pack_size_t = method(:pack_size_t_for_test)
            unpack_handle_list = method(:unpack_handle_list_for_test)
            pointer_pack = pointer_pack_for_test

            adapter.define_singleton_method(:create_stdout_pipe) { [101, 202] }
            adapter.define_singleton_method(:initialize_proc_thread_attribute_list) do
              FakeProc.new do |attribute_list, count, flags, size_ptr|
                events << [:initialize_attribute_list, attribute_list == 0 ? :size_query : :initialize, count, flags]
                size_ptr[0, Fiddle::SIZEOF_SIZE_T] = pack_size_t.call(64)
                1
              end
            end
            adapter.define_singleton_method(:update_proc_thread_attribute) do
              FakeProc.new do |attribute_list, flags, attribute, handle_list, byte_count, previous, return_size|
                attribute_list_seen = attribute_list
                events << [
                  :update_attribute,
                  flags,
                  attribute,
                  unpack_handle_list.call(handle_list),
                  byte_count,
                  previous,
                  return_size
                ]
                1
              end
            end
            adapter.define_singleton_method(:delete_proc_thread_attribute_list) do
              FakeProc.new { |attribute_list| events << [:delete_attribute_list, attribute_list] }
            end
            adapter.define_singleton_method(:create_process_w) do
              FakeProc.new do |_app, _command, _process_attrs, _thread_attrs, inherit_handles, flags, _env, _dir, startup_info, process_info|
                events << [
                  :create_process,
                  inherit_handles,
                  flags,
                  startup_info.unpack1('L<'),
                  startup_info.byteslice(Val3dityProcessAdapter::STARTUPINFO_SIZE, Fiddle::SIZEOF_VOIDP).unpack1(pointer_pack)
                ]
                process_info[0, process_info.bytesize] = [301, 302, 303, 304].pack('Q<Q<L<L<')
                1
              end
            end
            adapter.define_singleton_method(:close_handle) do
              FakeProc.new { |handle| events << [:close_handle, handle] }
            end
            adapter.define_singleton_method(:start_reader_thread) do |total_states:, total_transitions:|
              events << [:start_reader_thread, total_states, total_transitions]
            end

            adapter.start(total_states: 3, total_transitions: 4)

            assert_includes events, [
              :update_attribute,
              0,
              Val3dityProcessAdapter::PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
              [202],
              Fiddle::SIZEOF_VOIDP,
              0,
              0
            ]
            create_event = events.find { |event| event.first == :create_process }
            assert_equal 1, create_event[1]
            assert_equal(
              Val3dityProcessAdapter::CREATE_NO_WINDOW | Val3dityProcessAdapter::EXTENDED_STARTUPINFO_PRESENT,
              create_event[2]
            )
            assert_equal Val3dityProcessAdapter::STARTUPINFOEX_SIZE, create_event[3]
            assert_equal Fiddle::Pointer[attribute_list_seen].to_i, create_event[4]
            assert_includes events, [:close_handle, 202]
            assert_includes events, [:start_reader_thread, 3, 4]
            assert_equal :delete_attribute_list, events.last.first
          end

          def test_start_deletes_attribute_list_when_create_process_fails
            adapter = Val3dityProcessAdapter.new(args: ['val3dity.exe'], current_dir: Dir.tmpdir)
            events = []
            pack_size_t = method(:pack_size_t_for_test)

            adapter.define_singleton_method(:create_stdout_pipe) { [101, 202] }
            adapter.define_singleton_method(:initialize_proc_thread_attribute_list) do
              FakeProc.new do |attribute_list, _count, _flags, size_ptr|
                events << [:initialize_attribute_list, attribute_list == 0 ? :size_query : :initialize]
                size_ptr[0, Fiddle::SIZEOF_SIZE_T] = pack_size_t.call(64)
                1
              end
            end
            adapter.define_singleton_method(:update_proc_thread_attribute) do
              FakeProc.new { |_attribute_list, *_args| events << [:update_attribute]; 1 }
            end
            adapter.define_singleton_method(:delete_proc_thread_attribute_list) do
              FakeProc.new { |_attribute_list| events << [:delete_attribute_list] }
            end
            adapter.define_singleton_method(:create_process_w) do
              FakeProc.new { |_app, *_args| events << [:create_process]; 0 }
            end

            assert_raises(RuntimeError) do
              adapter.start(total_states: 0, total_transitions: 0)
            end
            assert_includes events, [:create_process]
            assert_includes events, [:delete_attribute_list]
          end

          private

          def pack_size_t_for_test(value)
            if Fiddle::SIZEOF_SIZE_T == 8
              [value].pack('Q<')
            else
              [value].pack('L<')
            end
          end

          def pointer_pack_for_test
            Fiddle::SIZEOF_VOIDP == 8 ? 'Q<' : 'L<'
          end

          def unpack_handle_list_for_test(handle_list)
            format = pointer_pack_for_test
            handle_list.bytes.each_slice(Fiddle::SIZEOF_VOIDP).map do |bytes|
              bytes.pack('C*').unpack1(format)
            end
          end

          def build_adapter(wait_result:, exit_code:, terminate_result: 1)
            adapter = Val3dityProcessAdapter.new(args: [], current_dir: Dir.tmpdir)
            adapter.instance_variable_set(:@process_handle, 123)
            adapter.define_singleton_method(:wait_for_single_object) do
              wait_result.respond_to?(:call) ? wait_result : FakeWait.new(wait_result)
            end
            adapter.define_singleton_method(:get_process_exit_code) do
              raise 'exit code unavailable' if exit_code.nil?

              exit_code
            end
            adapter.define_singleton_method(:terminate_process) do
              FakeWait.new(terminate_result)
            end
            adapter.define_singleton_method(:kill_process_tree) {}
            adapter.define_singleton_method(:close) do
              @closed = true
              @process_handle = 0
            end
            adapter.define_singleton_method(:closed?) do
              @closed == true
            end
            adapter
          end

          class FakeWait
            def initialize(result)
              @result = result
            end

            def call(*_args)
              @result
            end
          end

          class FakeWaitSequence
            def initialize(results)
              @results = results
            end

            def call(*_args)
              @results.length > 1 ? @results.shift : @results.first
            end
          end

          class FakeProc
            def initialize(&block)
              @block = block
            end

            def call(*args)
              @block.call(*args)
            end
          end
        end
      end
    end
  end
end
