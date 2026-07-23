# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/validity/val3dity_run_orchestration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityRunOrchestrationTest < Minitest::Test
          FakeResult = Struct.new(:error, keyword_init: true)

          def setup
            @original_ui = Object.const_get(:UI) if Object.const_defined?(:UI)
            Object.send(:remove_const, :UI) if Object.const_defined?(:UI)
            Object.const_set(:UI, fake_ui)
          end

          def teardown
            Object.send(:remove_const, :UI) if Object.const_defined?(:UI)
            Object.const_set(:UI, @original_ui) if @original_ui
          end

          def test_completed_session_drains_progress_builds_report_and_invokes_callback
            session = FakeSession.new(finished: true, terminated: false, exit_code: 0)
            events = []
            callback_result = nil

            returned = build_orchestration(
              session,
              events: events,
              build_result: ->(exit_code) {
                events << [:build_result, exit_code]
                FakeResult.new(error: nil)
              },
              callback: ->(result) { callback_result = result }
            ).start

            assert_same session, returned
            assert_equal [
              [:register, session],
              [:timer, 0.1, true],
              [:drain, :val3dity],
              [:timer, 0.2, true],
              [:join_reader],
              [:drain, :val3dity],
              [:progress_complete, :val3dity],
              [:stop_timer, true],
              [:close],
              [:unregister, session],
              [:timer, 0.05, false],
              [:build_result, 0]
            ], events
            assert_nil callback_result.error
          end

          def test_terminated_session_returns_error_without_building_report
            session = FakeSession.new(finished: true, terminated: true, exit_code: nil)
            events = []
            callback_result = nil

            build_orchestration(
              session,
              events: events,
              build_result: ->(_exit_code) { raise 'should not build report' },
              callback: ->(result) { callback_result = result }
            ).start

            assert_instance_of RuntimeError, callback_result.error
            assert_equal 'val3dity validation was canceled.', callback_result.error.message
            assert_includes events, [:close]
            assert_includes events, [:unregister, session]
          end

          def test_build_result_error_is_returned_to_callback
            session = FakeSession.new(finished: true, terminated: false, exit_code: 0)
            error = RuntimeError.new('report failed')
            callback_result = nil

            build_orchestration(
              session,
              events: [],
              build_result: ->(_exit_code) { raise error },
              callback: ->(result) { callback_result = result }
            ).start

            assert_same error, callback_result.error
          end

          def test_reader_timeout_is_returned_to_callback_without_building_report
            session = FakeSession.new(finished: true, terminated: false, exit_code: 0, reader_finished: false)
            callback_result = nil

            build_orchestration(
              session,
              events: [],
              build_result: ->(_exit_code) { raise 'should not build report' },
              callback: ->(result) { callback_result = result }
            ).start

            assert_instance_of RuntimeError, callback_result.error
            assert_match(/output reader did not finish/, callback_result.error.message)
          end

          def test_finished_error_is_returned_to_callback_without_polling_forever
            error = RuntimeError.new('wait failed')
            session = FakeSession.new(finished: error, terminated: false, exit_code: nil)
            events = []
            callback_result = nil

            build_orchestration(
              session,
              events: events,
              build_result: ->(_exit_code) { raise 'should not build report' },
              callback: ->(result) { callback_result = result }
            ).start

            assert_same error, callback_result.error
            assert_includes events, [:close]
            assert_includes events, [:unregister, session]
          end

          def test_inactive_report_timer_does_not_build_result_or_callback
            session = FakeSession.new(finished: true, terminated: false, exit_code: 0)
            events = []
            callback_called = false
            active_calls = 0

            build_orchestration(
              session,
              events: events,
              active: proc {
                active_calls += 1
                active_calls < 3
              },
              build_result: ->(_exit_code) {
                events << [:build_result]
                FakeResult.new(error: nil)
              },
              callback: ->(_result) { callback_called = true }
            ).start

            refute_includes events, [:build_result]
            refute callback_called
          end

          private

          def build_orchestration(session, events:, build_result:, callback:, active: nil)
            progress = FakeProgress.new(events)
            Val3dityRunOrchestration.new(
              session: session,
              progress: progress,
              progress_step: :val3dity,
              callback: callback,
              register_session: ->(active_session) { events << [:register, active_session] },
              unregister_session: ->(active_session) { events << [:unregister, active_session] },
              drain_progress: ->(_active_session, _active_progress, active_step) { events << [:drain, active_step] },
              build_result: build_result,
              error_result: ->(error) { FakeResult.new(error: error) },
              active: active
            )
          end

          def fake_ui
            events = nil
            Class.new do
              define_singleton_method(:events=) { |value| events = value }
              define_singleton_method(:start_timer) do |interval, repeat, &block|
                events << [:timer, interval, repeat] if events
                block.call
              end
              define_singleton_method(:stop_timer) do |timer_id|
                events << [:stop_timer, timer_id] if events
                true
              end
            end.tap { |ui| ui.events = [] }
          end

          class FakeSession
            attr_reader :exit_code

            def initialize(finished:, terminated:, exit_code:, reader_finished: nil)
              @finished = finished
              @terminated = terminated
              @exit_code = exit_code
              @reader_finished = reader_finished
            end

            def finished?
              raise @finished if @finished.is_a?(Exception)

              @finished
            end

            def terminated?
              @terminated
            end

            def join_reader
              current_events << [:join_reader]
              @reader_finished
            end

            def close
              current_events << [:close]
            end

            def current_events
              Object.const_get(:UI).instance_variable_get(:@unused) || Thread.current[:val3dity_orchestration_events] || []
            end
          end

          class FakeProgress
            def initialize(events)
              @events = events
              Thread.current[:val3dity_orchestration_events] = events
              Object.const_get(:UI).events = events
            end

            def complete(step)
              @events << [:progress_complete, step]
            end
          end
        end
      end
    end
  end
end
