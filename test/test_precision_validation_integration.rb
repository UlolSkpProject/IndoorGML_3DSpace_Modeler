# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    def self.command_dispatcher
      IndoorCore::CommandDispatcher.new
    end

    module IndoorCore
      module UiFeedback; end

      class LocalVertexNormalizer
        DEFAULT_TOLERANCE_MM = 0.001
      end

      module IndoorGmlConverter
        class ExportProgressDialog
          def initialize
            @base_initialized = true
          end

          private

          def init_script
            'base'
          end
        end

        class Val3dityRunner
          class Val3dityResult
            attr_reader :error

            def initialize(valid:, error: nil)
              @valid = valid
              @error = error
            end

            def valid?
              @valid == true
            end

            def error?
              !@error.nil?
            end
          end

          attr_reader :start_recheck_step, :preserve_calls, :recheck_calls

          def initialize(*_args, **_options)
            @preserve_calls = 0
            @recheck_calls = 0
          end

          def start(progress: nil, progress_step: :val3dity, recheck_step: :extension_recheck,
                    report_step: :report, active: nil, &callback)
            @start_recheck_step = recheck_step
            callback&.call(nil)
            :started
          end

          private

          def preserve_strict_validation!(raw_report)
            @preserve_calls += 1
            raw_report
          end

          def recheck_overlap_errors!(raw_report, progress: nil, progress_step: nil)
            @recheck_calls += 1
            raw_report
          end

          def build_result_after_process(_exit_code, _progress = nil,
                                         recheck_step: :extension_recheck,
                                         report_step: :report)
            Val3dityResult.new(valid: true)
          end

          def error_result(error)
            Val3dityResult.new(valid: false, error: error)
          end
        end
      end

      class CommandDispatcher
        def validation_operation_running?
          false
        end

        def check_validity
          :fast_check
        end

        private

        def validation_close_state
          { overlap_tol: -1 }
        end

        def perform_check_validity(_session)
          :fast_perform
        end

        def start_val3dity_validation(_session, _path)
          :started
        end

        def handle_validation_result(_session, _result, _path)
          :handled
        end
      end
    end
  end
end

require_relative '../indoor3d/application/precision_validation/validation_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationIntegrationTest < Minitest::Test
        def test_profile_steps_keep_fast_recheck_and_remove_it_from_precision
          fast_keys = PrecisionValidation.steps_for(:fast).map(&:first)
          precision_keys = PrecisionValidation.steps_for(:precision).map(&:first)

          assert_includes fast_keys, :extension_recheck
          assert_includes fast_keys, :application_profile
          refute_includes precision_keys, :extension_recheck
          assert_includes precision_keys, :lvn
          assert_includes precision_keys, :application_profile
        end

        def test_precision_dialog_uses_precision_steps
          dialog = PrecisionValidation.with_profile(:precision) do
            IndoorGmlConverter::ExportProgressDialog.new
          end
          script = dialog.send(:init_script)

          assert_includes script, 'lvn'
          assert_includes script, 'overlap_tol 0.01 mm'
          assert_includes script, 'application_profile'
          refute_includes script, 'extension_recheck'
        end

        def test_precision_runner_disables_recheck_but_fast_runner_keeps_it
          precision = PrecisionValidation.with_profile(:precision) do
            IndoorGmlConverter::Val3dityRunner.new('input.gml')
          end
          fast = PrecisionValidation.with_profile(:fast) do
            IndoorGmlConverter::Val3dityRunner.new('input.gml')
          end

          precision.start {}
          fast.start {}

          assert_nil precision.start_recheck_step
          assert_equal :extension_recheck, fast.start_recheck_step

          precision.send(:preserve_strict_validation!, {})
          precision.send(:recheck_overlap_errors!, {})
          fast.send(:preserve_strict_validation!, {})
          fast.send(:recheck_overlap_errors!, {})

          assert_equal 0, precision.preserve_calls
          assert_equal 0, precision.recheck_calls
          assert_equal 1, fast.preserve_calls
          assert_equal 1, fast.recheck_calls
        end

        def test_exit_code_is_exposed_and_nonzero_is_classified_as_crash
          runner = IndoorGmlConverter::Val3dityRunner.new('input.gml')
          success = runner.send(:build_result_after_process, 0)

          assert_equal 0, success.exit_code
          assert_equal :completed, success.process_status

          error = assert_raises(PrecisionValidation::Val3dityProcessExitError) do
            runner.send(:build_result_after_process, 3221225477)
          end
          failure = runner.send(:error_result, error)

          assert_equal 3221225477, failure.exit_code
          assert_equal :crashed, failure.process_status
          assert_match(/0xC0000005/, failure.error.message)
        end

        def test_validation_state_records_requested_profile
          dispatcher = CommandDispatcher.new
          state = PrecisionValidation.with_profile(:precision) do
            dispatcher.send(:validation_close_state)
          end

          assert_equal :precision, state[:validation_profile]
          assert_equal false, state[:lvn_running]
        end
      end
    end
  end
end
