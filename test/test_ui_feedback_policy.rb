# frozen_string_literal: true

require 'minitest/autorun'

class UiFeedbackPolicyTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_feedback_policy_uses_one_persistent_dispatcher
    source = File.read(File.join(ROOT, 'indoor3d/ui/ui_feedback.rb'))

    assert_includes source, 'UI.start_timer(DISPATCH_INTERVAL_SECONDS, true)'
    assert_includes source, 'def start_dispatcher'
    assert_includes source, 'def dispatch_pending_feedback'
    assert_includes source, 'UiFeedback.start_dispatcher if defined?(UI)'
    refute_includes source, 'UI.start_timer(0, false)'
    refute_includes source, 'UI.start_timer(0.5'
  end

  def test_feedback_calls_enqueue_instead_of_showing_ui_inline
    source = File.read(File.join(ROOT, 'indoor3d/ui/ui_feedback.rb'))

    assert_match(/def notify\(message\)\s+enqueue_feedback\(:notification, message\)/m, source)
    assert_match(/def defer_modal\(message, \*arguments\)\s+enqueue_feedback\(:modal, message, arguments\)/m, source)
    assert_includes source, 'ready_after_tick:'
    assert_includes source, 'return false if @dispatcher_tick <= item[:ready_after_tick].to_i'
  end

  def test_repeating_dispatcher_guards_modal_reentry
    source = File.read(File.join(ROOT, 'indoor3d/ui/ui_feedback.rb'))

    assert_includes source, 'return false if @dispatching_modal == true'
    assert_includes source, '@dispatching_modal = true'
    assert_includes source, '@dispatching_modal = false'
  end

  def test_notification_failure_stays_non_modal
    source = File.read(File.join(ROOT, 'indoor3d/ui/ui_feedback.rb'))

    assert_includes source, 'fallback_non_modal'
    assert_includes source, 'Sketchup.status_text = message'
  end

  def test_cell_space_commands_never_create_post_bulk_timers_or_messageboxes
    source = File.read(File.join(ROOT, 'indoor3d/ui/commands/cell_space_commands.rb'))

    refute_includes source, 'UI.messagebox('
    refute_includes source, 'UI.start_timer('
    assert_includes source, 'UiFeedback.publish_result'
    assert_includes source, 'UiFeedback.notify'
  end

  def test_toolbar_type_change_uses_one_batch_call
    source = File.read(File.join(ROOT, 'indoor3d/ui/commands/cell_space_commands.rb'))

    assert_includes source, 'indoor_model.change_cell_space_types('
    refute_match(/cell_space_groups\.each.*change_cell_space_type/m, source)
  end

  def test_indoor_model_conversion_never_creates_post_bulk_ui_timer
    source = File.read(File.join(ROOT, 'indoor3d/application/indoor_model/ui_feedback.rb'))

    assert_includes source, 'UiFeedback.publish_result'
    assert_includes source, 'UiFeedback.notify'
    refute_includes source, 'UI.start_timer('
    refute_includes source, 'UI.messagebox('
  end
end
