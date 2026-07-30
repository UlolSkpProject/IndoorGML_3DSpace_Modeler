# frozen_string_literal: true

# Runtime probe for the persistent UI feedback dispatcher.
#
# Requirements:
# - Start from a new, empty SketchUp model.
# - Reload the current extension before running this file so UiFeedback's
#   persistent dispatcher timer is already registered.
#
# Flow:
# 1. Confirm the dispatcher existed before the bulk operation starts.
# 2. Run the existing 3000 CellSpace batch stress probe.
# 3. Queue one modal message after the bulk operation returns.
# 4. Return control to SketchUp. The already-existing dispatcher must consume
#    the queued modal on a later dispatch turn and show it exactly once.

Object.send(:remove_const, :IndoorGMLDispatcherMessageboxStressProbe) \
  if Object.const_defined?(:IndoorGMLDispatcherMessageboxStressProbe, false)

module IndoorGMLDispatcherMessageboxStressProbe
  EXPECTED_COUNT = 3000

  LOG_PATH = File.join(
    ENV['TEMP'] || ENV['TMP'] || '.',
    'IndoorGML_dispatcher_messagebox_stress.log'
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
    puts "[DISPATCHER MESSAGEBOX STRESS LOG ERROR] #{e.class}: #{e.message}"
    nil
  end

  def install_modal_probe(feedback)
    singleton = feedback.singleton_class
    original = singleton.instance_method(:show_modal_now)
    log_method = method(:log)

    singleton.send(:define_method, :show_modal_now) do |item|
      log_method.call("DISPATCH MODAL ENTER diagnostics=#{dispatcher_diagnostics.inspect}")
      begin
        result = original.bind(self).call(item)
        log_method.call("DISPATCH MODAL RETURN result=#{result.inspect}")
        result
      ensure
        singleton.send(:define_method, :show_modal_now, original)
        singleton.send(:private, :show_modal_now)
      end
    end
    singleton.send(:private, :show_modal_now)
  end

  def run
    File.write(LOG_PATH, '')

    core = ULOL::Indoor3DGmlModeler::IndoorCore
    feedback = core::UiFeedback
    diagnostics = feedback.dispatcher_diagnostics

    log('DISPATCHER MESSAGEBOX STRESS START')
    log("DISPATCHER BEFORE BULK #{diagnostics.inspect}")
    raise 'Persistent UI dispatcher is not running before bulk' unless feedback.dispatcher_started?

    install_modal_probe(feedback)

    stress_probe = File.join(__dir__, 'cell_space_batch_stress_probe.rb')
    raise "Missing stress probe: #{stress_probe}" unless File.file?(stress_probe)

    log('STARTING 3000 CELLSPACE BULK WITH PERSISTENT DISPATCHER ALREADY RUNNING')
    load stress_probe

    indoor_model = core::IndoorModel.current
    cells = Array(indoor_model.cell_spaces)
    states = Array(indoor_model.states)
    log("BULK RETURNED cells=#{cells.length} states=#{states.length}")
    raise "Expected #{EXPECTED_COUNT} CellSpaces" unless cells.length == EXPECTED_COUNT
    raise "Expected #{EXPECTED_COUNT} States" unless states.length == EXPECTED_COUNT

    message = <<~MESSAGE.strip
      Persistent dispatcher messagebox test after #{EXPECTED_COUNT} CellSpace Bulk Create.

      This dialog must appear exactly ONCE.
      Press OK, then confirm SketchUp remains responsive.
    MESSAGE

    queued = feedback.defer_modal(message)
    log("MODAL QUEUED result=#{queued.inspect} diagnostics=#{feedback.dispatcher_diagnostics.inspect}")
    raise 'Modal was not queued' unless queued

    log('RETURNING TO SKETCHUP; EXISTING DISPATCHER MUST DELIVER MODAL')
    true
  rescue StandardError => e
    log("DISPATCHER MESSAGEBOX STRESS ERROR #{e.class}: #{e.message}")
    Array(e.backtrace).each { |line| log("BACKTRACE #{line}") }
    false
  end
end

IndoorGMLDispatcherMessageboxStressProbe.run

nil
