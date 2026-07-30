# frozen_string_literal: true

# Verifies the post-bulk UI boundary by registering the zero-delay timer BEFORE
# the large CellSpace transaction starts. Because SketchUp cannot service the
# timer while the current Ruby call stack is busy, the callback should run on
# the first event-loop turn after the bulk probe returns.
#
# Requirements:
# - Start from a new, empty SketchUp model.
# - Load the current extension code before running this file.

Object.send(:remove_const, :IndoorGMLPrearmedMessageboxStressProbe) \
  if Object.const_defined?(:IndoorGMLPrearmedMessageboxStressProbe, false)

module IndoorGMLPrearmedMessageboxStressProbe
  EXPECTED_COUNT = 3000

  LOG_PATH = File.join(
    ENV['TEMP'] || ENV['TMP'] || '.',
    'IndoorGML_prearmed_messagebox_stress.log'
  )

  @payload = {
    ready: false,
    message: nil
  }

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
    puts "[PREARMED MESSAGEBOX LOG ERROR] #{e.class}: #{e.message}"
    nil
  end

  def arm_timer
    timer_id = nil
    timer_id = UI.start_timer(0, false) do
      begin
        log("CALLBACK ENTER timer_id=#{timer_id.inspect} ready=#{@payload[:ready].inspect}")

        UI.stop_timer(timer_id) if timer_id && UI.respond_to?(:stop_timer)
        log('CALLBACK TIMER STOPPED')

        unless @payload[:ready]
          log('CALLBACK ERROR payload not ready')
          next
        end

        log('BEFORE MESSAGEBOX')
        result = UI.messagebox(@payload[:message])
        log("AFTER MESSAGEBOX result=#{result.inspect}")
      rescue StandardError => e
        log("CALLBACK ERROR #{e.class}: #{e.message}")
        Array(e.backtrace).each { |line| log("BACKTRACE #{line}") }
      end
    end

    log("PREARMED TIMER timer_id=#{timer_id.inspect}")
    timer_id
  end

  def run
    File.write(LOG_PATH, '')
    model = Sketchup.active_model
    raise "Probe requires an empty model: root_entities=#{model.entities.length}" unless model.entities.length.zero?

    log('PREARMED MESSAGEBOX STRESS START')
    timer_id = arm_timer
    raise 'Prearmed zero-delay timer registration failed' if timer_id.nil? || timer_id == 0

    stress_probe = File.join(__dir__, 'cell_space_batch_stress_probe.rb')
    raise "Missing stress probe: #{stress_probe}" unless File.file?(stress_probe)

    log('STARTING 3000 CELLSPACE BULK AFTER TIMER REGISTRATION')
    load stress_probe

    core = ULOL::Indoor3DGmlModeler::IndoorCore
    indoor_model = core::IndoorModel.current
    cells = Array(indoor_model.cell_spaces)
    states = Array(indoor_model.states)

    log("BULK RETURNED TO PREARMED PROBE cells=#{cells.length} states=#{states.length}")
    unless cells.length == EXPECTED_COUNT && states.length == EXPECTED_COUNT
      raise "Expected #{EXPECTED_COUNT} CellSpaces and States, got cells=#{cells.length} states=#{states.length}"
    end

    @payload[:message] = <<~MESSAGE.strip
      Pre-armed messagebox test after #{EXPECTED_COUNT} CellSpace Bulk Create.

      This timer was registered BEFORE the bulk transaction.
      This dialog must appear exactly ONCE.
      Press OK, then confirm SketchUp remains responsive.
    MESSAGE
    @payload[:ready] = true

    log('PAYLOAD READY')
    log('RETURNING TO SKETCHUP EVENT LOOP')
    true
  rescue StandardError => e
    @payload[:message] = "Prearmed messagebox stress failed before completion:\n#{e.class}: #{e.message}"
    @payload[:ready] = true
    log("PREARMED MESSAGEBOX STRESS ERROR #{e.class}: #{e.message}")
    Array(e.backtrace).each { |line| log("BACKTRACE #{line}") }
    false
  end
end

IndoorGMLPrearmedMessageboxStressProbe.run

nil
