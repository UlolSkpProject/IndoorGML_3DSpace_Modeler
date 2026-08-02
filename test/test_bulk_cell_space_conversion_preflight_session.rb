# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/bulk_cell_space_conversion_preflight_session'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class BulkCellSpaceConversionPreflightSessionTest < Minitest::Test
        Infrastructure = ThreadedProgressInfrastructure

        class FakeAdapter
          attr_reader :calls

          def initialize(invalid_prepare: [], invalid_geometry: [], invalid_target: [])
            @invalid_prepare = invalid_prepare
            @invalid_geometry = invalid_geometry
            @invalid_target = invalid_target
            @calls = []
          end

          def prepare(job, index)
            @calls << [:prepare, job, index, Thread.current.object_id]
            return [nil, error(job, 'prepare')] if @invalid_prepare.include?(job)

            [job.merge(job_id: "cell_space_conversion_#{index}").freeze, nil]
          end

          def validate_geometry(job)
            @calls << [:geometry, job[:name], Thread.current.object_id]
            return [nil, error(job[:name], 'geometry')] if @invalid_geometry.include?(job[:name])

            [job, nil]
          end

          def validate_target(job)
            @calls << [:target, job[:name], Thread.current.object_id]
            return [nil, error(job[:name], 'target')] if @invalid_target.include?(job[:name])

            [job, nil]
          end

          def empty_plan_error
            error('unknown group', 'empty')
          end

          private

          def error(group, reason)
            { group: group.is_a?(Hash) ? group[:name] : group, reason: reason }
          end
        end

        def test_successful_session_preserves_order_and_runs_on_main_thread
          jobs = [{ name: 'A' }, { name: 'B' }, { name: 'C' }]
          adapter = FakeAdapter.new
          session = build_session(jobs, adapter, max_items_per_slice: 1)

          snapshot = run_to_terminal(session)

          assert_equal :completed, snapshot[:type]
          assert_equal :completed, snapshot[:stage]
          assert_equal %w[A B C], session.plan.map { |job| job[:name] }
          assert_equal %w[cell_space_conversion_0 cell_space_conversion_1 cell_space_conversion_2],
                       session.plan.map { |job| job[:job_id] }
          assert_empty session.errors
          assert_equal [Thread.current.object_id], adapter.calls.map(&:last).uniq
          assert_equal Thread.current.object_id, snapshot[:main_thread_id]
          assert_equal Thread.current.object_id, snapshot[:current_thread_id]
          assert_in_delta 100.0, snapshot[:overall_percent], 0.0001
        end

        def test_errors_remain_grouped_in_original_stage_order
          jobs = [{ name: 'prepare_bad' }, { name: 'geometry_bad' }, { name: 'target_bad' }, { name: 'ok' }]
          adapter = FakeAdapter.new(
            invalid_prepare: [jobs[0]],
            invalid_geometry: ['geometry_bad'],
            invalid_target: ['target_bad']
          )
          session = build_session(jobs, adapter)

          snapshot = run_to_terminal(session)

          assert_equal :completed, snapshot[:type]
          assert_equal ['ok'], session.plan.map { |job| job[:name] }
          assert_equal [
            { group: 'prepare_bad', reason: 'prepare' },
            { group: 'geometry_bad', reason: 'geometry' },
            { group: 'target_bad', reason: 'target' }
          ], session.errors
          assert_equal 1, snapshot[:preparation_error_count]
          assert_equal 1, snapshot[:geometry_error_count]
          assert_equal 1, snapshot[:target_error_count]
        end

        def test_empty_input_reports_same_preflight_empty_error_shape
          session = build_session([], FakeAdapter.new)

          snapshot = run_to_terminal(session)

          assert_equal :completed, snapshot[:type]
          assert_empty session.plan
          assert_equal [{ group: 'unknown group', reason: 'empty' }], session.errors
          assert_equal 1, snapshot[:error_count]
        end

        def test_cancel_during_prepare_never_runs_later_stages
          jobs = Array.new(100) { |index| { name: "job_#{index}" } }
          adapter = FakeAdapter.new
          session = build_session(jobs, adapter, max_items_per_slice: 5)
          session.start
          session.tick
          session.cancel!

          snapshot = run_existing_to_terminal(session)

          assert_equal :cancelled, snapshot[:type]
          assert_nil session.plan
          assert adapter.calls.any? { |call| call.first == :prepare }
          refute adapter.calls.any? { |call| call.first == :geometry }
          refute adapter.calls.any? { |call| call.first == :target }
        end

        def test_stage_runner_exposes_predictive_budget_metrics
          jobs = Array.new(20) { |index| { name: "job_#{index}" } }
          session = build_session(jobs, FakeAdapter.new, max_items_per_slice: 2)

          snapshot = run_to_terminal(session)

          assert snapshot[:predictive_budget]
          assert_operator snapshot[:slice_count], :>, 0
          assert_operator snapshot[:max_slice_items], :<=, 2
          assert_equal 20, snapshot[:plan_count]
        end

        private

        def build_session(jobs, adapter, max_items_per_slice: 3)
          Infrastructure::BulkCellSpaceConversionPreflightSession.new(
            jobs: jobs,
            adapter: adapter,
            slice_budget_ms: 8.0,
            max_items_per_slice: max_items_per_slice,
            predictive_budget: true
          )
        end

        def run_to_terminal(session)
          session.start
          run_existing_to_terminal(session)
        end

        def run_existing_to_terminal(session)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
          until session.terminal?
            session.tick
            raise 'preflight session timeout' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          end
          session.snapshot
        end
      end
    end
  end
end
