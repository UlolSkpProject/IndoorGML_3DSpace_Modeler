# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionProgressApplyContractTest < Minitest::Test
        def test_apply_patch_delegates_to_existing_bulk_conversion_entrypoint
          source = read_dev_file('cell_space_conversion_progress_apply_patch.rb')

          assert_includes source, '@indoor_model.convert_cell_space_jobs_bulk('
          assert_includes source, 'original_active_path: @conversion_active_path'
          assert_includes source, "operation_name: '[DEV] Progress CellSpace Conversion'"
          refute_includes source, '.start_operation('
          refute_includes source, '.commit_operation'
          refute_includes source, '.abort_operation'
        end

        def test_apply_requires_preflight_policy_and_explicit_confirmation
          source = read_dev_file('cell_space_conversion_progress_apply_patch.rb')

          assert_includes source, 'CellSpaceConversionApplyPolicy.new'
          assert_includes source, '@apply_decision.allowed?'
          assert_includes source, 'UI.messagebox('
          assert_includes source, 'answer == IDYES'
        end

        def test_safety_patch_blocks_context_with_different_source_preservation_contract
          source = read_dev_file('cell_space_conversion_progress_apply_safety_patch.rb')

          assert_includes source, 'indoor_model.editing?'
          assert_includes source, 'indoor_model.validation_focus_active?'
          assert_includes source, 'separate source-preservation contract'
        end

        def test_history_guard_blocks_global_undo_redo_without_recorded_apply
          source = read_dev_file('cell_space_conversion_apply_history_guard_patch.rb')

          assert_includes source, 'apply_history_state.request_undo!'
          assert_includes source, 'apply_history_state.request_redo!'
          assert_includes source, 'Undo blocked:'
          assert_includes source, 'Redo blocked:'
          assert_includes source, 'passed = passed == true'
        end

        def test_history_wait_patch_polls_transaction_replay_before_confirming
          source = read_dev_file('cell_space_conversion_apply_history_wait_patch.rb')

          assert_includes source, 'UI.start_timer(HISTORY_POLL_INTERVAL, true)'
          assert_includes source, 'indoor_model.transaction_replay_pending?'
          assert_includes source, 'stable_samples: HISTORY_STABLE_SAMPLES'
          assert_includes source, 'apply_history_state.confirm_undone!(matches: true)'
          assert_includes source, 'apply_history_state.confirm_redone!(matches: true)'
          assert_includes source, 'history_pending_verification(:undone, :undo_pending)'
          assert_includes source, 'history_pending_verification(:redone, :redo_pending)'
        end

        def test_runner_definition_loads_history_stack_and_is_reload_safe
          runner = read_dev_file('cell_space_conversion_progress_apply_runner.rb')
          policy = read_dev_file('cell_space_conversion_apply_policy.rb')

          assert_includes runner, "require_relative 'cell_space_conversion_apply_direct_history_patch'"
          assert_includes runner, 'max_apply_jobs:'
          assert_includes runner, 'unless const_defined?(:TERMINAL_PHASES, false)'
          assert_includes runner, 'Undo 완료는 비동기 감시 후 자동 검증됩니다.'
          assert_includes policy, 'DEFAULT_MAX_APPLY_JOBS = 5'
        end

        def test_auto_run_file_contains_no_runner_definition
          source = read_dev_file('run_cell_space_conversion_progress_apply.rb')

          assert_includes source, "require_relative 'cell_space_conversion_progress_apply_runner'"
          assert_includes source, 'CellSpaceConversionProgressApplyRunner.run!'
          refute_includes source, 'module CellSpaceConversionProgressApplyRunner'
        end

        private

        def read_dev_file(name)
          File.read(
            File.expand_path(
              "../dev/threaded_progress_infrastructure/#{name}",
              __dir__
            )
          )
        end
      end
    end
  end
end
