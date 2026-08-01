# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/core'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ThreadedProgressInfrastructureCoreTest < Minitest::Test
        Infrastructure = ThreadedProgressInfrastructure

        def test_mailbox_preserves_fifo_order_and_drains_available_events
          mailbox = Infrastructure::ProgressMailbox.new
          mailbox.publish(type: :started, completed: 0)
          mailbox.publish(type: :progress, completed: 1)

          events = mailbox.drain

          assert_equal %i[started progress], events.map { |event| event[:type] }
          assert_equal [0, 1], events.map { |event| event[:completed] }
          assert events.all?(&:frozen?)
          assert mailbox.empty?
        end

        def test_cancellation_token_is_idempotent
          token = Infrastructure::CancellationToken.new

          refute token.cancelled?
          assert token.cancel!
          assert token.cancel!
          assert token.cancelled?
        end

        def test_worker_runs_on_a_distinct_thread_and_completes
          mailbox = Infrastructure::ProgressMailbox.new
          token = Infrastructure::CancellationToken.new
          main_thread_id = Thread.current.object_id
          worker = Infrastructure::PureRubyWorker.new(
            mailbox: mailbox,
            cancellation_token: token,
            total: 6,
            work_per_item: 50,
            progress_interval: 0.001,
            yield_interval: 0.001,
            checkpoint_iterations: 1
          )

          worker.start
          assert worker.join(2), 'worker did not finish'
          events = mailbox.drain
          terminal = events.last

          assert_equal :started, events.first[:type]
          assert_equal :completed, terminal[:type]
          assert_equal 6, terminal[:completed]
          refute_equal main_thread_id, terminal[:worker_thread_id]
          assert_kind_of Integer, terminal[:checksum]
          assert_operator terminal[:checkpoint_count], :>, 0
        end

        def test_worker_can_cancel_inside_a_single_large_item
          mailbox = Infrastructure::ProgressMailbox.new
          token = Infrastructure::CancellationToken.new
          worker = Infrastructure::PureRubyWorker.new(
            mailbox: mailbox,
            cancellation_token: token,
            total: 1,
            work_per_item: 10_000_000,
            progress_interval: 0.001,
            yield_interval: 0.001,
            checkpoint_iterations: 100
          )

          worker.start
          sleep(0.01)
          token.cancel!

          assert worker.join(2), 'worker did not stop after cancellation'
          terminal = mailbox.drain.last

          assert_equal :cancelled, terminal[:type]
          assert_equal 0, terminal[:completed]
          assert_operator terminal[:checkpoint_count], :>, 0
        end

        def test_pre_cancelled_worker_publishes_cancelled_terminal_event
          mailbox = Infrastructure::ProgressMailbox.new
          token = Infrastructure::CancellationToken.new
          token.cancel!
          worker = Infrastructure::PureRubyWorker.new(
            mailbox: mailbox,
            cancellation_token: token,
            total: 10,
            work_per_item: 10
          )

          worker.start
          assert worker.join(2), 'worker did not finish'
          events = mailbox.drain

          assert_equal :started, events.first[:type]
          assert_equal :cancelled, events.last[:type]
          assert_equal 0, events.last[:completed]
        end

        def test_core_has_no_sketchup_or_html_dialog_dependency
          source = File.read(
            File.expand_path('../dev/threaded_progress_infrastructure/core.rb', __dir__)
          )

          refute_includes source, 'Sketchup::'
          refute_includes source, 'UI::HtmlDialog'
          refute_includes source, 'UI.start_timer'
        end
      end
    end
  end
end
