# frozen_string_literal: true

# Runs production LocalVertexNormalizer on every selected manifold solid.
# Each target uses its own SketchUp operation through LVN. Successful targets
# remain normalized; failed targets are rolled back without stopping the scan.
#
# SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_normalize_selected_solids.rb'
# LvnNormalizeSelectedSolids.run

require 'json'
require 'tmpdir'
require 'time'

root = File.expand_path('..', __dir__)
require File.join(root, 'indoor3d', 'application', 'local_vertex_normalizer') unless
  defined?(ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer)

module LvnNormalizeSelectedSolids
  LVN = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer

  module_function

  def run(tolerance_mm: LVN::DEFAULT_TOLERANCE_MM)
    model = Sketchup.active_model
    selected = model.selection.to_a
    solids = selected.select { |entity| manifold_solid?(entity) }
    skipped = selected.reject { |entity| manifold_solid?(entity) }

    if solids.empty?
      puts '[LVN SELECTED NORMALIZE] selected manifold solids=0'
      return nil
    end

    result = {
      schema: 'ulol.lvn_normalize_selected_solids.v1',
      generated_at: Time.now.iso8601(3),
      tolerance_mm: tolerance_mm.to_f,
      selected_count: selected.length,
      candidate_count: solids.length,
      skipped_non_solid_count: skipped.length,
      success_count: 0,
      failure_count: 0,
      successes: [],
      failures: []
    }

    solids.each_with_index do |entity, index|
      identity = entity_identity(entity)
      before = geometry_counts(entity)

      begin
        normalizer = LVN.new(tolerance_mm, model: model)
        report = normalizer.normalize(entity, manage_operation: true)
        after = geometry_counts(entity)
        final_coplanar = compact_final_coplanar_report(
          report_value(report, :final_coplanar_face_merge)
        )

        result[:success_count] += 1
        result[:successes] << identity.merge(
          geometry_before: before,
          geometry_after: after,
          source_collapsed_sliver_cleanup: compact_report(
            report_value(report, :source_collapsed_sliver_cleanup) ||
              report_value(report, :source_altitude_sliver_collapse)
          ),
          grid_altitude_sliver_retriangulation: compact_report(
            report_value(report, :grid_altitude_sliver_retriangulation) ||
              normalizer.instance_variable_get(:@grid_altitude_sliver_retriangulation_stats_v2)
          ),
          final_coplanar_face_merge: final_coplanar
        )

        puts format(
          '[LVN SELECTED NORMALIZE] %d/%d OK   %s PID=%s',
          index + 1,
          solids.length,
          identity[:name],
          identity[:pid]
        )
        print_final_coplanar_result(final_coplanar)
      rescue StandardError => error
        result[:failure_count] += 1
        result[:failures] << identity.merge(
          geometry_before: before,
          error_class: error.class.to_s,
          error_message: error.message.to_s,
          backtrace: Array(error.backtrace).first(20)
        )

        warn format(
          '[LVN SELECTED NORMALIZE] %d/%d FAIL %s PID=%s | %s: %s',
          index + 1,
          solids.length,
          identity[:name],
          identity[:pid],
          error.class,
          error.message
        )
      end
    end

    path = File.join(
      Dir.tmpdir,
      "lvn_normalize_selected_solids_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
    )
    File.open(path, 'w:UTF-8') do |file|
      file.write(JSON.pretty_generate(json_safe(result.merge(json_path: path))))
    end

    result[:json_path] = path
    $lvn_normalize_selected_solids = result

    puts '-' * 88
    puts format(
      '[LVN SELECTED NORMALIZE] selected=%d solids=%d success=%d failure=%d skipped=%d',
      result[:selected_count],
      result[:candidate_count],
      result[:success_count],
      result[:failure_count],
      result[:skipped_non_solid_count]
    )
    puts "[LVN SELECTED NORMALIZE] JSON: #{path}"
    puts '-' * 88

    nil
  end

  def manifold_solid?(entity)
    return false unless entity&.respond_to?(:valid?) && entity.valid?
    return false unless entity.respond_to?(:definition)
    return false unless entity.respond_to?(:manifold?)

    entity.manifold? == true
  rescue StandardError
    false
  end

  def entity_identity(entity)
    {
      pid: safe_persistent_id(entity),
      name: entity_display_name(entity),
      entity_class: entity.class.to_s,
      definition_name: (entity.definition.name.to_s rescue nil)
    }
  end

  def entity_display_name(entity)
    name = entity.respond_to?(:name) ? entity.name.to_s : ''
    return name unless name.empty?

    definition_name = entity.respond_to?(:definition) ? entity.definition.name.to_s : ''
    return definition_name unless definition_name.empty?

    entity.class.to_s
  rescue StandardError
    entity.class.to_s
  end

  def safe_persistent_id(entity)
    entity.persistent_id
  rescue StandardError
    nil
  end

  def geometry_counts(entity)
    entities = entity.definition.entities
    {
      faces: entities.grep(Sketchup::Face).count,
      edges: entities.grep(Sketchup::Edge).count,
      manifold: entity.respond_to?(:manifold?) ? entity.manifold? : nil
    }
  rescue StandardError => error
    {
      error: "#{error.class}: #{error.message}"
    }
  end

  def report_value(report, key)
    return nil unless report.respond_to?(:[])

    report[key] || report[key.to_s]
  rescue StandardError
    nil
  end

  def compact_report(report)
    return nil unless report.is_a?(Hash)

    keys = [
      :policy,
      :threshold_mm,
      :diagnostic_threshold_mm,
      :input_triangle_count,
      :output_triangle_count,
      :detected_sliver_count,
      :detected_low_altitude_count,
      :remaining_sliver_count,
      :remaining_low_altitude_count,
      :initial_invalid_pair_count,
      :final_invalid_pair_count,
      :attempted_patch_count,
      :accepted_patch_count,
      :invalid_pair_reduction,
      :affected_source_face_keys,
      :skipped,
      :skip_reason
    ]

    report.each_with_object({}) do |(key, value), compact|
      symbol = key.respond_to?(:to_sym) ? key.to_sym : key
      compact[symbol] = value if keys.include?(symbol)
    end
  rescue StandardError
    nil
  end

  def compact_final_coplanar_report(report)
    return nil unless report.is_a?(Hash)

    keys = [
      :applied,
      :restored,
      :fallback_reason,
      :plane_tolerance_mm,
      :angle_tolerance_deg,
      :source_face_count,
      :normal_component_count,
      :planar_group_count,
      :singleton_group_count,
      :merge_group_count,
      :merged_input_face_count,
      :removed_internal_edge_count,
      :expected_face_reduction,
      :actual_face_reduction,
      :grid_residual_mm
    ]

    report.each_with_object({}) do |(key, value), compact|
      symbol = key.respond_to?(:to_sym) ? key.to_sym : key
      compact[symbol] = value if keys.include?(symbol)
    end
  rescue StandardError => error
    { compact_error: "#{error.class}: #{error.message}" }
  end

  def print_final_coplanar_result(report)
    unless report.is_a?(Hash)
      puts '[LVN FINAL COPLANAR] report=missing'
      return nil
    end

    if report[:restored] == true
      puts format(
        '[LVN FINAL COPLANAR] RESTORED applied=false tol=%s angle=%s | %s',
        report[:plane_tolerance_mm],
        report[:angle_tolerance_deg],
        report[:fallback_reason]
      )
      return nil
    end

    puts format(
      '[LVN FINAL COPLANAR] applied=%s groups=%s faces=%s edges=%s reduction=%s/%s tol=%s angle=%s',
      report[:applied],
      report[:merge_group_count],
      report[:merged_input_face_count],
      report[:removed_internal_edge_count],
      report[:actual_face_reduction],
      report[:expected_face_reduction],
      report[:plane_tolerance_mm],
      report[:angle_tolerance_deg]
    )
    nil
  end

  def json_safe(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), hash|
        hash[key.to_s] = json_safe(item)
      end
    when Array
      value.map { |item| json_safe(item) }
    when Symbol
      value.to_s
    when String, Integer, Float, TrueClass, FalseClass, NilClass
      value
    else
      value.respond_to?(:to_a) ? json_safe(value.to_a) : value.to_s
    end
  end
end