# frozen_string_literal: true

# Production-shaped post-bulk modal feedback probe.
#
# Requirements:
# - Start from a new, empty SketchUp model.
# - Load the current extension code before running this file.
#
# Flow:
# 1. Reuse the 3000 CellSpace batch stress probe.
# 2. Do NOT publish a success notification.
# 3. Immediately schedule one modal through UiFeedback.defer_modal.
# 4. Return to SketchUp so the zero-delay timer can fire on the next event-loop turn.
#
# This matches the production failure/partial-failure path where notification and
# modal feedback are mutually exclusive.

stress_probe = File.join(__dir__, 'cell_space_batch_stress_probe.rb')
raise "Missing stress probe: #{stress_probe}" unless File.file?(stress_probe)

load stress_probe

Object.send(:remove_const, :IndoorGMLDeferredMessageboxStressProbe) \
  if Object.const_defined?(:IndoorGMLDeferredMessageboxStressProbe, false)

module IndoorGMLDeferredMessageboxStressProbe
  EXPECTED_COUNT = 3000

  LOG_PATH = File.join(
    ENV['TEMP'] || ENV['TMP'] || '.',
    'IndoorGML_deferred_messagebox_stress.log'
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
    puts "[DEFERRED MESSAGEBOX STRESS LOG ERROR] #{e.class}: #{e.message}"
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

    log('DEFERRED MESSAGEBOX STRESS START')
    log("RUNTIME cells=#{cells.length} states=#{states.length}")

    unless cells.length == EXPECTED_COUNT && states.length == EXPECTED_COUNT
      raise(
        "Expected #{EXPECTED_COUNT} CellSpaces and States after batch stress, " \
        "got cells=#{cells.length} states=#{states.length}"
      )
    end

    message = <<~MESSAGE.strip
      Deferred messagebox after #{EXPECTED_COUNT} CellSpace Bulk Create.

      This dialog must appear exactly ONCE.
      Press OK, then confirm SketchUp remains responsive.
    MESSAGE

    timer_id = core::UiFeedback.defer_modal(message)
    log("DEFERRED MODAL SCHEDULED timer_id=#{timer_id.inspect}")
    log('RETURNING TO SKETCHUP EVENT LOOP')

    true
  rescue StandardError => e
    log("DEFERRED MESSAGEBOX STRESS ERROR #{e.class}: #{e.message}")
    Array(e.backtrace).each { |line| log("BACKTRACE #{line}") }
    false
  end
end

IndoorGMLDeferredMessageboxStressProbe.run

nil
