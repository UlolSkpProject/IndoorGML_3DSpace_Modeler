# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end
    end
  end
end

require_relative '../indoor3d/application/progress/cooperative_fiber_runner'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class CooperativeFiberRunnerTest < Minitest::Test
          class FakeScheduler
            attr_reader :stopped

            def initialize
              @next_id = 0
              @timers = {}
              @stopped = []
            end

            def start(delay, repeat, &block)
              @next_id += 1
              @timers[@next_id] = {
                delay: delay,
                repeat: repeat,
                block: block
              }
              @next_id
            end

            def stop(timer_id)
              @stopped << timer_id
              @timers.delete(timer_id)
              true
            end

            def run_next_one_shot
              entry = @timers.find { |_id, timer| timer[:repeat] == false }
              return false unless entry

              timer_id, timer = entry
              @timers.delete(timer_id)
              timer[:block].call
              true
            end

            def run_repeating
              entry = @timers.find { |_id, timer| timer[:repeat] == true }
              return false unless entry

              entry.last[:block].call
              true
            end
          end

          class FakeView
            attr_reader :invalidate_count

            def initialize
              @invalidate_count = 0
            end

            def invalidate
              @invalidate_count += 1
            end
          end

          FakeModel = Struct.new(:active_view)

          def test_work_resumes_one_slice_per_timer_tick
            scheduler = FakeScheduler.new
            view = FakeView.new
            runner = CooperativeFiberRunner.new(
              model: FakeModel.new(view),
              timer_start: scheduler.method(:start),
              timer_stop: scheduler.method(:stop)
            )
            events = []

            assert runner.start { |yield_control|
              events << :slice_1
              yield_control.call
              events << :slice_2
              yield_control.call
              events << :slice_3
            }

            assert_empty events
            assert scheduler.run_next_one_shot
            assert_equal [:slice_1], events
            assert runner.active?

            assert scheduler.run_repeating
            assert_equal 1, view.invalidate_count

            assert scheduler.run_next_one_shot
            assert_equal %i[slice_1 slice_2], events
            assert scheduler.run_next_one_shot
            assert_equal %i[slice_1 slice_2 slice_3], events
            refute runner.active?
          end

          def test_close_is_idempotent
            scheduler = FakeScheduler.new
            runner = CooperativeFiberRunner.new(
              model: FakeModel.new(FakeView.new),
              timer_start: scheduler.method(:start),
              timer_stop: scheduler.method(:stop)
            )
            runner.start { |_yield_control| nil }

            assert runner.close
            refute runner.close
            refute runner.active?
          end
        end
      end
    end
  end
end
