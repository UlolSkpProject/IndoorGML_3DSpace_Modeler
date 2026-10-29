# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/ui/commands/export_commands'

class ValidationResultFocusReportCloseTest < Minitest::Test
  ExportCommands = ULOL::Indoor3DGmlModeler::IndoorCore::ExportCommands

  class Indoor
    attr_accessor :can_restore
    attr_reader :restore_count

    def initialize(active: true, can_restore: true)
      @active = active
      @can_restore = can_restore
      @restore_count = 0
    end

    def validation_focus_active?
      @active
    end

    def close_validation_result_focus
      @restore_count += 1
      @can_restore
    end
  end

  class Progress
    attr_reader :close_count

    def initialize
      @close_count = 0
    end

    def on_request_close(&block)
      @on_request_close = block
    end

    def request_close
      @on_request_close.call
    end

    def close
      @close_count += 1
    end

    def visible?
      true
    end
  end

  class Session
    attr_reader :indoor_model, :progress, :completions

    def initialize(indoor)
      @indoor_model = indoor
      @progress = Progress.new
      @completions = []
    end

    def state
      { temp_file_running: false, val_running: false, completed: true }
    end

    def complete(reason:)
      @completions << reason
    end

    def result_ready?
      true
    end

    def running?
      false
    end
  end

  class Harness
    include ExportCommands
    attr_reader :validation_session, :validation_progress_dialog

    def initialize(session)
      @validation_session = session
      @validation_progress_dialog = session.progress
    end

    def attach_close_handler
      configure_validation_close_handler(@validation_session)
    end

    def close_previous
      close_previous_validation_result
    end
  end

  def test_dialog_close_restores_scene_before_completion
    indoor = Indoor.new
    session = Session.new(indoor)
    harness = Harness.new(session)
    harness.attach_close_handler

    assert_equal :close, session.progress.request_close
    assert_equal 1, indoor.restore_count
    assert_equal [:closed], session.completions
  end

  def test_dialog_close_failure_remains_open_and_does_not_complete_session
    indoor = Indoor.new(can_restore: false)
    session = Session.new(indoor)
    harness = Harness.new(session)
    harness.attach_close_handler

    assert_equal :keep_open, session.progress.request_close
    assert_equal 1, indoor.restore_count
    assert_empty session.completions
  end

  def test_new_validation_refuses_to_close_previous_result_if_restore_failed
    indoor = Indoor.new(can_restore: false)
    session = Session.new(indoor)
    harness = Harness.new(session)

    refute harness.close_previous
    assert_empty session.completions
    assert_equal 0, session.progress.close_count
  end

  def test_new_validation_closes_previous_result_after_restore
    indoor = Indoor.new
    session = Session.new(indoor)
    harness = Harness.new(session)

    assert harness.close_previous
    assert_equal 1, indoor.restore_count
    assert_equal 1, session.progress.close_count
    assert_equal [:restarted], session.completions
  end

  def test_no_validation_focus_needs_no_scene_restore
    indoor = Indoor.new(active: false)
    session = Session.new(indoor)
    harness = Harness.new(session)
    harness.attach_close_handler

    assert_equal :close, session.progress.request_close
    assert_equal 0, indoor.restore_count
    assert_equal [:closed], session.completions
  end
end
