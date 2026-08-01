# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/main_thread_slice_runner'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class MainThreadSliceRunnerTest < Minitest::Test
        Runner = ThreadedProgressInfrastructure::MainThreadSliceRunner

        class FakeClock
          def initialize
            @time = 0.0
          end

          def call
            @time
          end

          def advance(seconds)
            @time += seconds
          end
        end

        def test_time_budget_splits_work_across_ticks
          clock = FakeClock.new
          processed = []
          runner = Runner.new(
            total: 10,
            slice_budget_ms: 5.0,
            max_items_per_slice: 100,
            clock: clock
          ) do |index|
            processed << index
            clock.advance(0.002)
            index
          end

          first = runner.tick

          assert_equal :running, first[:type]
          assert_equal 3, first[:completed]
          assert_equal 3, first[:last_slice_items]
          assert_operator first[:last_slice_ms], :>=, 5.0

          runner.tick until runner.terminal?
          terminal = runner.snapshot

          assert_equal :completed, terminal[:type]
          assert_equal 10, terminal[:completed]
          assert_equal (0...10).to_a, processed
          assert_operator terminal[:slice_count], :>, 1
        end

        def test_max_item_limit_applies_when_steps_are_fast
          clock = FakeClock.new
          runner = Runner.new(
            total: 5,
            slice_budget_ms: 100.0,
            max_items_per_slice: 2,
            clock: clock
          ) { |index| index }

          snapshot = runner.tick

          assert_equal 2, snapshot[:completed]
          assert_equal 2, snapshot[:last_slice_items]
          assert_equal :running, snapshot[:type]
        end

        def test_cancel_is_observed_before_next_item
          clock = FakeClock.new
          runner = Runner.new(total: 10, clock: clock) { |index| index }
          runner.start
          runner.cancel!

          snapshot = runner.tick

          assert_equal :cancelled, snapshot[:type]
          assert_equal 0, snapshot[:completed]
          assert snapshot[:terminal]
        end

        def test_step_failure_becomes_failed_terminal_state
          clock = FakeClock.new
          runner = Runner.new(total: 3, clock: clock) do |index|
            raise ArgumentError, 'expected test failure' if index == 1

            index
          end

          snapshot = runner.tick

          assert_equal :failed, snapshot[:type]
          assert_equal 1, snapshot[:completed]
          assert_equal 'ArgumentError', snapshot[:error_class]
          assert_equal 'expected test failure', snapshot[:error_message]
        end

        def test_empty_job_completes_without_slice
          clock = FakeClock.new
          called = false
          runner = Runner.new(total: 0, clock: clock) do |_index|
            called = true
          end

          snapshot = runner.start

          assert_equal :completed, snapshot[:type]
          assert_equal 100.0, snapshot[:percent]
          assert_equal 0, snapshot[:slice_count]
          refute called
        end

        def test_runner_has_no_sketchup_or_ui_dependency
          source = File.read(
            File.expand_path('../dev/threaded_progress_infrastructure/main_thread_slice_runner.rb', __dir__)
          )

          refute_includes source, 'Sketchup::'
          refute_includes source, 'UI.start_timer'
          refute_includes source, 'UI::HtmlDialog'
        end
      end
    end
  end
end
