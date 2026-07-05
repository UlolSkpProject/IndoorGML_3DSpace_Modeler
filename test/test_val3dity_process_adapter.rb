# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

require_relative '../indoor3d/export/val3dity_process_adapter'

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

          private

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
        end
      end
    end
  end
end
