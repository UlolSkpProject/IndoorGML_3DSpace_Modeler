# frozen_string_literal: true

# Full runtime probe for the post-bulk UI feedback boundary.
#
# Requirements:
# - Start from a new, empty SketchUp model.
# - Load the current extension code before running this file.
#
# Flow:
# 1. Reuse the existing 3000 CellSpace batch stress probe.
# 2. Confirm the 3000-cell runtime exists and is valid enough to continue.
# 3. Publish the normal success feedback through UI::Notification.
# 4. Immediately schedule a modal message through UiFeedback.defer_modal.
#    This uses UI.start_timer(0, false), not an arbitrary delay.
#
# PASS criteria:
# - Batch stress reports PASS.
# - SketchUp does not crash after the bulk operation returns.
# - A non-modal success notification is requested.
# - The modal message appears exactly once after control returns to the event loop.

stress_probe = File.join(__dir__, 'cell_space_batch_stress_probe.rb')
raise "Missing stress probe: #{stress_probe}" unless File.file?(stress_probe)

load stress_probe

Object.send(:remove_const, :IndoorGMLUiFeedbackStressProbe) \
  if Object.const_defined?(:IndoorGMLUiFeedbackStressProbe, false)

module IndoorGMLUiFeedbackStressProbe
  EXPECTED_COUNT = 3000

  LOG_PATH = File.join(
    ENV['TEMP'] || ENV['TMP'] || '.',
    'IndoorGML_ui_feedback_stress.log'
  )

  module_function

  def log(message)
    line = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')}] #{message}"
    puts line
    File.open(LOG_PATH, 'a') do |file|
      file.puts(line)
      file.flush
    end
    line
  rescue StandardError => e
    puts "[UI FEEDBACK STRESS LOG ERROR] #{e.class}: #{e.message}"
    nil
  end

  def run
    File.write(LOG_PATH, '')

    core = ULOL::Indoor3DGmlModeler::IndoorCore
    indoor_model = core::IndoorModel.current
    raise 'IndoorModel.current unavailable' unless indoor_model
    raise 'UiFeedback unavailable' unless core.const_defined?(:UiFeedback, false)

    cells = Array(indoor_model.cell_spaces)
    states = Array(indoor_model.states)

    log('UI FEEDBACK STRESS START')
    log("RUNTIME cells=#{cells.length} states=#{states.length}")

    unless cells.length == EXPECTED_COUNT && states.length == EXPECTED_COUNT
      raise(
        "Expected #{EXPECTED_COUNT} CellSpaces and States after batch stress, " \
        "got cells=#{cells.length} states=#{states.length}"
      )
    end

    success_message =
      "CellSpace conversion completed: #{cells.length} converted, 0 errors."

    notification_result = core::UiFeedback.notify(success_message)
    log("NOTIFICATION REQUESTED result=#{notification_result.inspect}")

    modal_message = <<~MESSAGE.strip
      Deferred messagebox test after #{EXPECTED_COUNT} CellSpace Bulk Create.

      This dialog must appear exactly ONCE.
      Press OK, then confirm SketchUp remains responsive.
    MESSAGE

    timer_id = core::UiFeedback.defer_modal(modal_message)
    log("DEFERRED MODAL SCHEDULED timer_id=#{timer_id.inspect}")
    log('RETURNING TO SKETCHUP EVENT LOOP')

    true
  rescue StandardError => e
    log("UI FEEDBACK STRESS ERROR #{e.class}: #{e.message}")
    Array(e.backtrace).each { |line| log("BACKTRACE #{line}") }
    false
  end
end

IndoorGMLUiFeedbackStressProbe.run

nil
