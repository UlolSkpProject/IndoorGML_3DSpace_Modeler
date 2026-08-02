# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionRollbackFailureContractTest < Minitest::Test
        def test_runner_uses_exact_production_bulk_conversion_entrypoint
          source = read_dev_file('cell_space_conversion_rollback_failure_runner.rb')

          assert_includes source, 'indoor_model.convert_cell_space_jobs_bulk('
          assert_includes source, 'original_active_path: conversion_active_path'
          assert_includes source, 'activate_root_context: true'
          refute_includes source, '.start_operation('
          refute_includes source, '.commit_operation'
          refute_includes source, '.abort_operation'
        end

        def test_failure_is_injected_after_entity_creation_and_before_topology_sync
          source = read_dev_file('cell_space_conversion_rollback_failure_runner.rb')

          assert_includes source, 'method_name: :synchronize_topology_after_bulk_conversion'
          assert_includes source, 'Injected failure before topology synchronization'
          assert_includes source, 'ScopedMethodOverride.new('
          assert_includes source, 'override.call do'
        end

        def test_runner_verifies_geometry_runtime_source_and_transaction_rollback
          source = read_dev_file('cell_space_conversion_rollback_failure_runner.rb')

          assert_includes source, 'feature_counts_unchanged'
          assert_includes source, 'root_entities_unchanged'
          assert_includes source, 'source_snapshot_unchanged'
          assert_includes source, 'active_path_restored'
          assert_includes source, 'transaction_abort_clean'
          assert_includes source, 'transaction_replay_pending?'
          assert_includes source, 'onTransactionAbort'
          assert_includes source, 'onTransactionCommit'
          assert_includes source, 'onTransactionUndo'
          assert_includes source, 'onTransactionRedo'
        end

        def test_runner_is_limited_and_scheduled_after_console_callback
          source = read_dev_file('cell_space_conversion_rollback_failure_runner.rb')
          auto_run = read_dev_file('run_cell_space_conversion_rollback_failure.rb')

          assert_includes source, 'MAX_JOBS = 5'
          assert_includes source, 'UI.start_timer(0, false)'
          assert_includes source, 'jobs exceed safety limit'
          assert_includes auto_run, "require_relative 'cell_space_conversion_rollback_failure_runner'"
          assert_includes auto_run, 'CellSpaceConversionRollbackFailureRunner.run!'
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
