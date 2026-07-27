# frozen_string_literal: true

# Runs the production LocalVertexNormalizer against every selected group/component
# independently, but always aborts the SketchUp operation so no geometry change is
# kept. Only failures are printed in detail.
#
# SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_selected_failure_scan.rb'
# LvnSelectedFailureScan.run

require 'json'
require 'tmpdir'
require 'time'

root = File.expand_path('..', __dir__)
require File.join(root, 'indoor3d', 'application', 'local_vertex_normalizer') unless
  defined?(ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer)

module LvnSelectedFailureScan
  LVN = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer

  module_function

  def run(tolerance_mm: LVN::DEFAULT_TOLERANCE_MM, write_json: true)
    model = Sketchup.active_model
    selected = model.selection.to_a
    candidates, skipped = selected.partition { |entity| normalizable_entity?(entity) }

    result = {
      schema: 'ulol.lvn_selected_failure_scan.v1',
      generated_at: Time.now.iso8601(3),
      tolerance_mm: Float(tolerance_mm),
      selected_count: selected.length,
      candidate_count: candidates.length,
      success_count: 0,
      failure_count: 0,
      skipped: skipped.map { |entity| entity_summary(entity) },
      failures: []
    }

    if candidates.empty?
      puts '[LVN FAILURE SCAN] No selected Group/ComponentInstance candidates.'
      $lvn_selected_failure_scan = result
      return result
    end

    puts "\n#{'=' * 100}"
    puts '[LVN SELECTED FAILURE SCAN]'
    puts "selected=#{selected.length} candidates=#{candidates.length} skipped=#{skipped.length}"
    puts "tolerance_mm=#{tolerance_mm}"
    puts 'Every candidate is normalized inside its own operation and ALWAYS rolled back.'
    puts '=' * 100

    candidates.each_with_index do |entity, index|
      failure = scan_one(model, entity, tolerance_mm, index + 1, candidates.length)
      if failure
        result[:failures] << failure
      else
        result[:success_count] += 1
      end
    end

    result[:failure_count] = result[:failures].length

    if write_json
      json_path = File.join(
        Dir.tmpdir,
        "lvn_selected_failure_scan_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
      )
      File.open(json_path, 'w:UTF-8') { |file| file.write(JSON.pretty_generate(result)) }
      result[:json_path] = json_path
    end

    $lvn_selected_failure_scan = result
    print_summary(result)
    result
  end

  def scan_one(model, entity, tolerance_mm, ordinal, total)
    info = entity_summary(entity)
    operation_started = false
    failure = nil
    normalizer = LVN.new(tolerance_mm, model: model)

    begin
      operation_started = model.start_operation(
        "LVN failure scan #{ordinal}/#{total}",
        true
      )
      raise LVN::OperationError, 'SketchUp refused to start diagnostic operation' unless operation_started

      # Full production normalization path including the exact in-memory hard
      # gate and SketchUp rebuild. This probe owns the outer operation.
      normalizer.normalize(entity, manage_operation: false)
    rescue StandardError => error
      failure = info.merge(
        error_class: error.class.name,
        error_message: error.message.to_s,
        backtrace: Array(error.backtrace).first(12)
      )
    ensure
      if operation_started
        begin
          aborted = model.abort_operation
          if aborted == false
            rollback_message = 'SketchUp returned false from abort_operation'
            if failure
              failure[:rollback_error] = rollback_message
            else
              failure = info.merge(
                error_class: 'LVN_SCAN_ROLLBACK_FAILURE',
                error_message: rollback_message,
                backtrace: []
              )
            end
          end
        rescue StandardError => abort_error
          rollback_message = "#{abort_error.class}: #{abort_error.message}"
          if failure
            failure[:rollback_error] = rollback_message
            failure[:rollback_backtrace] = Array(abort_error.backtrace).first(12)
          else
            failure = info.merge(
              error_class: 'LVN_SCAN_ROLLBACK_FAILURE',
              error_message: rollback_message,
              backtrace: Array(abort_error.backtrace).first(12)
            )
          end
        end
      end
    end

    if failure
      puts "\n[FAIL #{ordinal}/#{total}] #{target_label(info)}"
      puts "  #{failure[:error_class]}: #{failure[:error_message]}"
      puts "  ROLLBACK ERROR: #{failure[:rollback_error]}" if failure[:rollback_error]
    end
    failure
  end

  def normalizable_entity?(entity)
    return false unless entity.respond_to?(:valid?) && entity.valid?
    return true if defined?(Sketchup::Group) && entity.is_a?(Sketchup::Group)
    return true if defined?(Sketchup::ComponentInstance) && entity.is_a?(Sketchup::ComponentInstance)

    false
  rescue StandardError
    false
  end

  def entity_summary(entity)
    definition = entity.respond_to?(:definition) ? entity.definition : nil
    {
      class: entity.class.name,
      name: safe_string(entity, :name),
      persistent_id: safe_value(entity, :persistent_id),
      entity_id: safe_value(entity, :entityID),
      definition_name: definition ? safe_string(definition, :name) : nil,
      definition_persistent_id: definition ? safe_value(definition, :persistent_id) : nil
    }
  rescue StandardError => error
    {
      class: entity.class.name,
      name: nil,
      persistent_id: nil,
      entity_id: nil,
      definition_name: nil,
      definition_persistent_id: nil,
      summary_error: "#{error.class}: #{error.message}"
    }
  end

  def safe_value(object, method_name)
    object.respond_to?(method_name) ? object.public_send(method_name) : nil
  rescue StandardError
    nil
  end

  def safe_string(object, method_name)
    value = safe_value(object, method_name)
    value.nil? ? nil : value.to_s
  end

  def target_label(info)
    name = info[:name].to_s
    name = '(unnamed)' if name.empty?
    "#{name} PID=#{info[:persistent_id].inspect} EID=#{info[:entity_id].inspect}"
  end

  def print_summary(result)
    puts "\n#{'=' * 100}"
    puts '[LVN FAILURE SCAN RESULT]'
    puts "candidates=#{result[:candidate_count]} success=#{result[:success_count]} failures=#{result[:failure_count]} skipped=#{result[:skipped].length}"

    if result[:failures].empty?
      puts 'No normalization failures.'
    else
      result[:failures].each_with_index do |failure, index|
        puts "\nFAIL #{index + 1}/#{result[:failures].length}"
        puts "  name=#{failure[:name].inspect}"
        puts "  pid=#{failure[:persistent_id].inspect} entity_id=#{failure[:entity_id].inspect}"
        puts "  definition=#{failure[:definition_name].inspect}"
        puts "  error=#{failure[:error_class]}"
        puts "  message=#{failure[:error_message]}"
        puts "  rollback_error=#{failure[:rollback_error]}" if failure[:rollback_error]
      end
    end

    puts "\nJSON: #{result[:json_path]}" if result[:json_path]
    puts 'Full result: $lvn_selected_failure_scan'
    puts '=' * 100
  end
end
