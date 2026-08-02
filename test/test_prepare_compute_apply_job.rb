# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/prepare_compute_apply_job'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class TestPrepareComputeApplyJob < Minitest::Test
        Infrastructure = ThreadedProgressInfrastructure

        def test_contract_weighted_progress_and_transitions
          contract = Infrastructure::StagedJobContract.new

          assert_in_delta 10.0, contract.overall_percent(phase: :prepare, phase_percent: 50.0), 0.0001
          assert_in_delta 50.0, contract.overall_percent(phase: :compute, phase_percent: 50.0), 0.0001
          assert contract.valid_transition?(from: :compute, to: :apply)
          refute contract.valid_transition?(from: :prepare, to: :apply)
        end

        def test_full_pipeline_completes_with_main_thread_sliced_compute_and_apply
          compute_thread_ids = []
          apply_thread_id = nil
          job = Infrastructure::PrepareComputeApplyJob.new(
            prepare_total: 20,
            prepare_step: proc { |index| { index: index, value: index + 1 } },
            compute_step: proc do |input, _index|
              compute_thread_ids << Thread.current.object_id
              [input[:index], input[:value] * 2]
            end,
            apply_step: proc do |computed|
              apply_thread_id = Thread.current.object_id
              computed.sum { |item| item[1] }
            end,
            finalize_step: proc { |apply_result, _computed| apply_result == 420 },
            max_items_per_slice: 4
          )

          snapshot = run_to_terminal(job)

          assert_equal :completed, snapshot[:type]
          assert_equal :completed, snapshot[:phase]
          assert_equal 20, snapshot[:prepare_count]
          assert_equal 20, snapshot[:compute_count]
          assert_equal 420, snapshot[:apply_result]
          assert_equal true, snapshot[:finalize_result]
          assert_equal [Thread.current.object_id], compute_thread_ids.uniq
          assert_equal Thread.current.object_id, snapshot[:compute_thread_id]
          assert_equal Thread.current.object_id, apply_thread_id
          assert_equal :main_thread_sliced, snapshot[:compute_execution]
          assert_nil snapshot[:worker_thread_id]
          refute snapshot[:worker_alive]
          assert_operator snapshot[:compute_slice_count], :>=, 5
          assert_in_delta 100.0, snapshot[:overall_percent], 0.0001
        end

        def test_cancel_during_prepare_never_calls_compute_or_apply
          compute_called = false
          apply_called = false
          job = Infrastructure::PrepareComputeApplyJob.new(
            prepare_total: 1_000,
            prepare_step: proc { |index| index },
            compute_step: proc do |input, _index|
              compute_called = true
              input
            end,
            apply_step: proc do |_computed|
              apply_called = true
              true
            end,
            max_items_per_slice: 10
          )

          job.start
          job.tick
          job.cancel!
          snapshot = run_existing_job_to_terminal(job)

          assert_equal :cancelled, snapshot[:type]
          refute compute_called
          refute apply_called
          assert_equal 0, snapshot[:compute_count]
        end

        def test_cancel_during_compute_never_calls_apply
          apply_called = false
          job = Infrastructure::PrepareComputeApplyJob.new(
            prepare_total: 100,
            prepare_step: proc { |index| index },
            compute_step: proc { |input, _index| input * 2 },
            apply_step: proc do |_computed|
              apply_called = true
              true
            end,
            max_items_per_slice: 10
          )

          job.start
          job.tick until job.phase == :compute
          job.tick
          job.cancel!
          snapshot = run_existing_job_to_terminal(job)

          assert_equal :cancelled, snapshot[:type]
          refute apply_called
          assert_operator snapshot[:compute_count], :>, 0
          assert_operator snapshot[:compute_count], :<, 100
          refute snapshot[:worker_alive]
        end

        def test_apply_failure_calls_rollback_and_fails
          rollback_error = nil
          job = Infrastructure::PrepareComputeApplyJob.new(
            prepare_total: 5,
            prepare_step: proc { |index| index },
            compute_step: proc { |input, _index| input * 3 },
            apply_step: proc { |_computed| raise 'injected apply failure' },
            rollback_step: proc do |error, _apply_result, computed|
              rollback_error = error.message
              computed.length
            end
          )

          snapshot = run_to_terminal(job)

          assert_equal :failed, snapshot[:type]
          assert snapshot[:rollback_attempted]
          assert_equal 5, snapshot[:rollback_result]
          assert_equal 'injected apply failure', rollback_error
          assert_equal 'RuntimeError', snapshot[:error_class]
        end

        private

        def run_to_terminal(job)
          job.start
          run_existing_job_to_terminal(job)
        end

        def run_existing_job_to_terminal(job)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
          until job.terminal?
            job.tick
            raise 'test job timeout' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          end
          job.snapshot
        end
      end
    end
  end
end
