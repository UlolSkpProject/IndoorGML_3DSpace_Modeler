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

          private

          def build_adapter(wait_result:, exit_code:)
            adapter = Val3dityProcessAdapter.new(args: [], current_dir: Dir.tmpdir)
            adapter.instance_variable_set(:@process_handle, 123)
            adapter.define_singleton_method(:wait_for_single_object) do
              FakeWait.new(wait_result)
            end
            adapter.define_singleton_method(:get_process_exit_code) do
              raise 'exit code unavailable' if exit_code.nil?

              exit_code
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
        end
      end
    end
  end
end
