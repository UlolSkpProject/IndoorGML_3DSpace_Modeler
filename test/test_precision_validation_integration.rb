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
        class Progress
          attr_reader :result_payload, :clear_result_count, :detail_payload, :cancellable_values

          def initialize
            @next_callback = nil
            @clear_result_count = 0
            @cancellable_values = []
          end

          def running(*) = true
          def detail(*args, **payload)
            @detail_payload = { step: args.first }.merge(payload)
            true
          end
          def complete(*) = true

          def cancellable(value)
            @cancellable_values << value
          end

          def result(**payload)
            @result_payload = payload
          end

          def on_next(&block)
            @next_callback = block
          end

          def clear_result
            @clear_result_count += 1
            @result_payload = nil
          end

          def trigger_next
            callback = @next_callback
            @next_callback = nil
            callback&.call
          end
        end

        def test_profile_steps_keep_fast_recheck_and_remove_it_from_precision
          fast_keys = PrecisionValidation.steps_for(:fast).map(&:first)
          precision_keys = PrecisionValidation.steps_for(:precision).map(&:first)

          assert_includes fast_keys, :extension_recheck
          refute_includes precision_keys, :extension_recheck
          assert_includes precision_keys, :lvn
          assert_includes precision_keys, :crash_scan
          refute_includes fast_keys, :application_profile
          refute_includes precision_keys, :application_profile
        end

        def test_precision_dialog_uses_precision_steps
          dialog = PrecisionValidation.with_profile(:precision) do
            IndoorGmlConverter::ExportProgressDialog.new
          end
          script = dialog.send(:init_script)

          assert_includes script, 'lvn'
          assert_includes script, 'crash_scan'
          assert_includes script, '4 processes'
          assert_includes script, 'overlap_tol 0.01 mm'
          refute_includes script, 'application_profile'
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

        def test_next_is_required_before_lvn_and_again_before_final_export
          crash_cells = [Struct.new(:id).new('cell_A'), Struct.new(:id).new('cell_B')]
          normalize_options = nil
          indoor_model = Object.new
          indoor_model.define_singleton_method(:local_vertex_normalize) do |_tolerance, **options|
            normalize_options = options
            {
              cell_space_count: 2,
              already_normalized_cell_space_count: 0,
              normalization_failed_cell_space_count: 0,
              skipped_previous_failure_cell_space_count: 0
            }
          end
          state = {}
          session = Struct.new(:state, :progress, :indoor_model, :workspace).new(
            state,
            Progress.new,
            indoor_model,
            Struct.new(:gml_path).new('final.gml')
          )
          dispatcher = CommandDispatcher.new
          export_call = nil
          dispatcher.define_singleton_method(:start_temp_file_creation) do |_session, **options|
            export_call = options
          end

          dispatcher.send(:await_precision_lvn_confirmation, session, crash_cells)

          assert_nil normalize_options
          assert_nil export_call
          assert_equal :lvn, state[:precision_waiting_for]
          assert_includes session.progress.result_payload[:message], '- cell_A'
          assert_equal [:next], session.progress.result_payload[:actions]

          session.progress.trigger_next

          assert_equal crash_cells, normalize_options[:cell_spaces]
          assert_equal false, normalize_options[:activate_edit_context]
          assert_equal :continue, normalize_options[:failure_policy]
          assert_nil export_call
          assert_equal 2, state.dig(:lvn_report, :cell_space_count)
          assert_equal :val3dity, state[:precision_waiting_for]
          assert_equal 'LVN 완료', session.progress.result_payload[:title]

          session.progress.trigger_next

          assert_equal({ output_path: 'final.gml', step: :temp_file }, export_call)
          assert_nil state[:precision_waiting_for]
          assert_equal 2, session.progress.clear_result_count
        end

        def test_no_crash_skips_lvn_and_waits_once_before_val3dity
          state = {}
          progress = Progress.new
          session = Struct.new(:state, :progress, :workspace).new(
            state,
            progress,
            Struct.new(:gml_path).new('final.gml')
          )
          dispatcher = CommandDispatcher.new
          export_call = nil
          dispatcher.define_singleton_method(:start_temp_file_creation) do |_session, **options|
            export_call = options
          end

          dispatcher.send(:await_precision_lvn_confirmation, session, [])

          assert_equal :val3dity, state[:precision_waiting_for]
          assert_equal 0, state.dig(:lvn_report, :cell_space_count)
          assert_includes progress.result_payload[:message], 'LVN 결과: 성공 0'
          assert_nil export_call

          progress.trigger_next

          assert_equal({ output_path: 'final.gml', step: :temp_file }, export_call)
        end

        def test_crash_scan_progress_shows_each_bucket_status_and_split_progress
          progress = Progress.new
          snapshot = {
            completed: 5,
            total_jobs: 9,
            active: 4,
            pending: 0,
            crash_cell_count: 1,
            categories: [
              {
                category: 'Room', status: :passed, cell_space_count: 20,
                completed_jobs: 1, total_jobs: 1, active_jobs: 0, pending_jobs: 0,
                split_count: 0, split_completed_jobs: 0, split_total_jobs: 0,
                aabb_passed_cell_space_count: 20, max_depth: 0, crash_cell_count: 0
              },
              {
                category: 'Stair 1/2', status: :splitting, cell_space_count: 12,
                completed_jobs: 4, total_jobs: 8, active_jobs: 4, pending_jobs: 0,
                split_count: 2, split_completed_jobs: 3, split_total_jobs: 7,
                aabb_passed_cell_space_count: 6, max_depth: 2, crash_cell_count: 1
              },
              {
                category: 'Stair 2/2', status: :empty, cell_space_count: 0,
                completed_jobs: 0, total_jobs: 0, active_jobs: 0, pending_jobs: 0,
                split_count: 0, split_completed_jobs: 0, split_total_jobs: 0,
                aabb_passed_cell_space_count: 0, max_depth: 0, crash_cell_count: 0
              },
              {
                category: PrecisionValidation::CrashIsolationPlan::COMBINED_CATEGORY, status: :waiting,
                cell_space_count: 8, completed_jobs: 0, total_jobs: 1,
                active_jobs: 0, pending_jobs: 1, split_count: 0,
                split_completed_jobs: 0, split_total_jobs: 0,
                aabb_passed_cell_space_count: 0, max_depth: 0, crash_cell_count: 0
              }
            ]
          }
          dispatcher = CommandDispatcher.new

          dispatcher.send(:precision_crash_scan_progress, progress, snapshot)

          assert_equal 56, progress.detail_payload[:percent]
          assert_includes progress.detail_payload[:message], '전체 job 5/9'
          log = progress.detail_payload[:current]
          assert_includes log, 'Room [crash 없음]'
          assert_includes log, 'Stair 1/2 [crash 발생 / 분할 중]'
          assert_includes log, '분할 2회, 하위 job 3/7, depth 2'
          assert_includes log, 'AABB 통과 CellSpace 6개'
          assert_includes log, 'Stair 2/2 [대상 없음]'
          assert_includes log, 'Door / Elevator / Window / Anchor [대기]'
        end
      end
    end
  end
end
