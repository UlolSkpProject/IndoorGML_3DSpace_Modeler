# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/progress/production_progress_session'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class ProductionProgressSessionTest < Minitest::Test
          class FakeClock
            def initialize(value = 10.0)
              @value = value
            end

            def call
              @value
            end

            def advance(seconds)
              @value += seconds
            end
          end

          class RecordingRenderer
            attr_reader :events

            def initialize(fail_on: nil)
              @events = []
              @fail_on = fail_on
            end

            %i[show update hide close].each do |method_name|
              define_method(method_name) do |snapshot = nil|
                raise "forced #{method_name} failure" if @fail_on == method_name

                @events << [method_name, snapshot]
                true
              end
            end
          end

          def build_session(total: 10, renderer: RecordingRenderer.new, cancellable: false, metadata: {})
            clock = FakeClock.new
            session = ProductionProgressSession.new(
              title: 'CellSpace 작업',
              total: total,
              renderer: renderer,
              clock: clock,
              cancellable: cancellable,
              metadata: metadata
            )
            [session, clock, renderer]
          end

          def test_idle_snapshot_is_immutable_and_normalized
            source = +'a'
            session, = build_session(total: -5, metadata: { source: [source] })
            snapshot = session.snapshot

            assert_equal :idle, snapshot[:status]
            assert_equal 0, snapshot[:total]
            assert_equal 0, snapshot[:completed]
            assert_equal 0.0, snapshot[:percent]
            refute snapshot[:active]
            refute snapshot[:terminal]
            refute snapshot[:closed]
            assert_equal({ source: ['a'] }, snapshot[:metadata])
            assert_predicate snapshot, :frozen?
            assert_predicate snapshot[:metadata], :frozen?
            assert_predicate snapshot[:metadata][:source], :frozen?
            assert_raises(FrozenError) { snapshot[:metadata][:source] << 'b' }
            refute source.frozen?
            source << 'b'
            assert_equal ['a'], snapshot[:metadata][:source]
          end

          def test_start_and_overall_update_publish_snapshots
            session, clock, renderer = build_session(total: 8)

            started = session.start(message: '준비')
            clock.advance(2.5)
            updated = session.update(completed: 3, message: '진행', telemetry: { items_per_second: 2 })

            assert_equal :running, started[:status]
            assert started[:active]
            assert_equal '준비', started[:message]
            assert_equal 0.0, started[:elapsed]
            assert_equal 3, updated[:completed]
            assert_in_delta 37.5, updated[:percent], 0.001
            assert_in_delta 2.5, updated[:elapsed], 0.001
            assert_equal({ items_per_second: 2 }, updated[:telemetry])
            assert_equal %i[show update], renderer.events.map(&:first)
          end

          def test_stage_lifecycle_tracks_percent_elapsed_and_history
            session, clock, = build_session(total: 4)
            session.start
            first = session.start_stage('prepare', total: 5, message: '준비 단계', metadata: { kind: :read })
            clock.advance(1.25)
            middle = session.update_stage(completed: 2, telemetry: { visited: 7 })
            clock.advance(0.75)
            finished = session.finish_stage(message: '준비 완료')
            second = session.start_stage('apply', total: 2, cancellable: false)

            assert_equal 'prepare', first[:stage][:name]
            assert_equal :running, first[:stage][:status]
            assert_equal 2, middle[:stage][:completed]
            assert_in_delta 40.0, middle[:stage][:percent], 0.001
            assert_in_delta 1.25, middle[:stage][:elapsed], 0.001
            assert_equal 7, middle[:stage][:telemetry][:visited]
            assert_equal :completed, finished[:stage][:status]
            assert_equal 5, finished[:stage][:completed]
            assert_in_delta 2.0, finished[:stage][:elapsed], 0.001
            assert_equal 1, second[:stages].length
            assert_equal 'prepare', second[:stages].first[:name]
            assert_equal 'apply', second[:stage][:name]
          end

          def test_stage_transition_requires_explicit_finish
            session, = build_session
            session.start
            session.start_stage('one', total: 1)

            error = assert_raises(ProductionProgressSession::StateError) do
              session.start_stage('two', total: 1)
            end
            assert_match(/while "one" is running/, error.message)
            idle_session = ProductionProgressSession.new(title: 'x', total: 1)
            assert_raises(ProductionProgressSession::StateError) do
              idle_session.update(completed: 1)
            end
            assert_raises(ProductionProgressSession::StateError) do
              idle_session.fail(ArgumentError.new('invalid'))
            end
            assert_nil idle_session.snapshot[:error]
            assert_raises(ProductionProgressSession::StateError) { session.complete.tap { session.update(completed: 1) } }
          end

          def test_cancellation_is_only_requested_during_cancellable_phase
            session, = build_session(cancellable: false)
            session.start

            refute session.request_cancel
            assert session.set_cancellable(true)
            assert session.request_cancel
            assert session.cancel_requested?
            assert session.snapshot[:cancel_requested]
            session.start_stage('apply', total: 1, cancellable: false)
            refute session.request_cancel
            cancelled = session.cancel(message: '사용자 취소')
            assert_equal :cancelled, cancelled[:status]
            assert cancelled[:terminal]
            refute cancelled[:active]
            refute cancelled[:cancellable]
            assert_equal '사용자 취소', cancelled[:message]
          end

          def test_complete_clamps_counts_and_records_terminal_telemetry
            session, clock, = build_session(total: 3, cancellable: true)
            session.start
            session.update(completed: 99)
            session.start_stage('finalize', total: 0)
            clock.advance(4)
            completed = session.complete(message: '완료', telemetry: { transition_count: 12 })

            assert_equal :completed, completed[:status]
            assert_equal 3, completed[:completed]
            assert_equal 100.0, completed[:percent]
            assert_equal :completed, completed[:stage][:status]
            assert_equal 100.0, completed[:stage][:percent]
            assert_in_delta 4.0, completed[:elapsed], 0.001
            assert_equal 12, completed[:telemetry][:transition_count]
            refute completed[:cancellable]
            assert session.terminal?
          end

          def test_failure_captures_error_without_mutating_previous_snapshots
            session, = build_session(total: 0)
            idle = session.snapshot
            session.start
            failed = session.fail(ArgumentError.new('잘못된 입력'))

            assert_equal :idle, idle[:status]
            assert_nil idle[:error]
            assert_equal :failed, failed[:status]
            assert_equal 'ArgumentError', failed[:error][:class]
            assert_equal '잘못된 입력', failed[:error][:message]
            assert_equal '잘못된 입력', failed[:message]
            assert_equal 0.0, failed[:percent]
            assert failed[:terminal]
            assert_predicate failed[:error], :frozen?
          end

          def test_renderer_failures_are_isolated_and_close_is_idempotent
            renderer = RecordingRenderer.new(fail_on: :update)
            session, = build_session(renderer: renderer)

            session.start
            updated = session.update(completed: 1)
            completed = session.complete
            first_close = session.close
            second_close = session.close

            assert_equal 1, updated[:renderer_error_count]
            assert_equal 2, completed[:renderer_error_count]
            assert first_close
            refute second_close
            assert session.closed?
            assert_equal %i[show hide close], renderer.events.map(&:first)
            assert_equal :completed, session.snapshot[:status]
          end
        end
      end
    end
  end
end
