# frozen_string_literal: true

require 'minitest/autorun'

class UiFeedbackPolicyTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_feedback_policy_uses_notification_and_zero_delay_event_turn
    source = File.read(File.join(ROOT, 'indoor3d/ui/ui_feedback.rb'))

    assert_includes source, 'UI::Notification.new'
    assert_includes source, 'UI.start_timer(0, false)'
    assert_includes source, 'UI.stop_timer(timer_id)'
    refute_includes source, 'UI.start_timer(0.5'
  end

  def test_notification_retention_does_not_attach_dismiss_button
    source = File.read(File.join(ROOT, 'indoor3d/ui/ui_feedback.rb'))

    assert_includes source, '@last_notification = notification'
    refute_match(/notification\.on_dismiss\s*(?:do|\{)/, source)
  end

  def test_cell_space_commands_do_not_show_modal_success_results_immediately
    source = File.read(File.join(ROOT, 'indoor3d/ui/commands/cell_space_commands.rb'))

    refute_includes source, 'UI.messagebox('
    assert_includes source, 'UiFeedback.publish_result'
    assert_includes source, 'UiFeedback.notify'
    assert_includes source, 'UiFeedback.defer_modal'
  end

  def test_toolbar_type_change_uses_one_batch_call
    source = File.read(File.join(ROOT, 'indoor3d/ui/commands/cell_space_commands.rb'))

    assert_includes source, 'indoor_model.change_cell_space_types('
    refute_match(/cell_space_groups\.each.*change_cell_space_type/m, source)
  end

  def test_indoor_model_conversion_uses_shared_feedback_policy
    source = File.read(File.join(ROOT, 'indoor3d/application/indoor_model/ui_feedback.rb'))

    assert_includes source, 'UiFeedback.publish_result'
    assert_includes source, 'UiFeedback.defer_modal'
    refute_includes source, 'UI.messagebox('
  end
end
