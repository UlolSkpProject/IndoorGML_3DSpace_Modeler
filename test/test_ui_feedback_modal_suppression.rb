# frozen_string_literal: true

require 'minitest/autorun'

MB_YESNO = 4 unless defined?(MB_YESNO)

module UI
  class << self
    attr_accessor :modal_suppression_messages, :modal_suppression_timers
  end

  def self.start_timer(_delay, _repeat = false, &block)
    self.modal_suppression_timers ||= []
    modal_suppression_timers << block
    modal_suppression_timers.length
  end

  def self.messagebox(message, *arguments)
    self.modal_suppression_messages ||= []
    modal_suppression_messages << [message, arguments]
    :messagebox_result
  end
end

module Sketchup
  class << self
    attr_accessor :status_text
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        class << self
          attr_accessor :modal_suppression_logs
        end

        def self.puts(message)
          self.modal_suppression_logs ||= []
          modal_suppression_logs << message
        end
      end
    end
  end
end

require_relative '../indoor3d/ui/ui_feedback'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class UiFeedbackModalSuppressionTest < Minitest::Test
        Feedback = UiFeedback

        def setup
          UI.modal_suppression_messages = []
          Logger.modal_suppression_logs = []
          Feedback.instance_variable_set(:@pending_feedback, [])
          Feedback.instance_variable_set(:@dispatcher_tick, 0)
          Feedback.instance_variable_set(:@dispatching_modal, false)
          Thread.current[Feedback::MODAL_SUPPRESSION_DEPTH_KEY] = 0
          Thread.current[Feedback::MODAL_SUPPRESSION_REASON_KEY] = nil
        end

        def teardown
          Thread.current[Feedback::MODAL_SUPPRESSION_DEPTH_KEY] = 0
          Thread.current[Feedback::MODAL_SUPPRESSION_REASON_KEY] = nil
        end

        def test_initial_refresh_scope_drops_modal_feedback
          result = Feedback.with_modal_suppressed(reason: :initial_runtime_refresh) do
            Feedback.defer_modal('Runtime refresh complete')
          end

          refute result
          dispatch_feedback
          assert_empty UI.modal_suppression_messages
          assert Logger.modal_suppression_logs.any? do |message|
            message.include?('reason=initial_runtime_refresh')
          end
          refute Feedback.modal_suppressed?
        end

        def test_confirmation_is_not_suppressed
          callback_result = nil

          result = Feedback.with_modal_suppressed(reason: :initial_runtime_refresh) do
            Feedback.confirm('Continue?', MB_YESNO) do |value|
              callback_result = value
            end
          end

          assert result
          dispatch_feedback
          assert_equal [['Continue?', [MB_YESNO]]], UI.modal_suppression_messages
          assert_equal :messagebox_result, callback_result
        end

        def test_modal_feedback_works_after_scope_ends
          Feedback.with_modal_suppressed(reason: :initial_runtime_refresh) do
            refute Feedback.defer_modal('hidden')
          end

          assert Feedback.defer_modal('visible')
          dispatch_feedback

          assert_equal [['visible', []]], UI.modal_suppression_messages
        end

        private

        def dispatch_feedback
          3.times { Feedback.send(:dispatch_pending_feedback) }
        end
      end
    end
  end
end
