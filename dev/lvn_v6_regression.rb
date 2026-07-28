# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

load File.join(__dir__, 'lvn_near_edge_stitch_experiment_v6.rb')

Object.send(:remove_const, :LvnV6Regression) if defined?(LvnV6Regression)

module LvnV6Regression
  LVN = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
  NORMALIZER = LvnNearEdgeStitchExperiment::StitchNormalizer
  DEFAULT_TOLERANCE_MM = LVN::DEFAULT_TOLERANCE_MM
  REPORT_DIR = File.expand_path('reports', __dir__).freeze

  BASELINE_FAILURES = {
    1_189_788 => { key: 'ijn58ryq', expected_v6: :success },
    1_106_041 => { key: 's8vadud8', expected_v6: :success },
    1_107_846 => { key: 'o6rz6ds0', expected_v6: :may_fail }
  }.freeze

  module_function

  def run(tolerance_mm: DEFAULT_TOLERANCE_MM)
    model = Sketchup.active_model
    selected = model.selection.to_a
    solids = selected.select { |entity| manifold_solid?(entity) }

    puts '=' * 110
    puts '[LVN V6 REGRESSION]'
    puts "selected=#{selected.length} manifold_solids=#{solids.length} tolerance=#{tolerance_mm} mm"
    puts '=' * 110

    if solids.empty?
      puts '[LVN V6 REGRESSION] selected manifold solids=0'
      return nil
    end

    puts "WARNING: baseline target count is 159, current manifold solid count=#{solids.length}" if solids.length != 159

    started_at = Time.now
    results = solids.each_with_index.map do |source, index|
      test_one(model, source, index + 1, solids.length, tolerance_mm.to_f)
    end
    finished_at = Time.now

    summary = build_summary(results, selected.length, solids.length, started_at, finished_at, tolerance_mm.to_f)
    report_path = write_report(summary)
    summary[:report_path] = report_path
    $lvn_v6_regression = summary
    print_summary(summary)
    nil
  rescue StandardError => error
    puts '[LVN V6 REGRESSION] FATAL'
    puts "#{error.class}: #{error.message}"
    puts Array(error.backtrace).first(20).join("\n")
    nil
  end

  def test_one(model, source, ordinal, total, tolerance_mm)
    pid = safe_pid(source)
    baseline = BASELINE_FAILURES[pid]
    before = entity_snapshot(source)
    copy = nil
    normalizer = nil
    error = nil
    report = nil
    after = nil
    started_at = Time.now

    begin
      copy = create_unique_copy(model, source)
      normalizer = NORMALIZER.new(tolerance_mm, model: model)
      report = normalizer.normalize(copy, manage_operation: true)
      after = entity_snapshot(copy)
    rescue StandardError => caught
      error = caught
      after = entity_snapshot(copy) if copy&.valid?
    ensure
      remove_copy(model, copy)
    end

    stitch_report = sanitize(normalizer&.near_edge_stitch_report || {})
    success = error.nil?
    baseline_status = baseline ? :previous_failure : :previous_success

    result = {
      index: ordinal,
      total: total,
      source_pid: pid,
      source_name: entity_name(source),
      baseline_status: baseline_status,
      baseline_key: baseline && baseline[:key],
      expected_v6: baseline && baseline[:expected_v6],
      success: success,
      regression: baseline_status == :previous_success && !success,
      target_unresolved: baseline && baseline[:expected_v6] == :success && !success,
      elapsed_sec: Time.now - started_at,
      source_before: before,
      normalized_after: after,
      geometry_counts_changed: geometry_counts_changed?(before, after, success),
      normalization_report: compact_normalization_report(report),
      stitch_report: stitch_report,
      error_class: error&.class&.to_s,
      error_message: error&.message,
      error_backtrace: error ? Array(error.backtrace).first(12) : []
    }

    print_result(result)
    result
  end

  def create_unique_copy(model, source)
    started = model.start_operation('LVN v6 regression copy', true)
    raise 'Could not start LVN v6 regression copy operation' unless started

    copy = source.respond_to?(:copy) ? source.copy : nil
    raise "Could not copy #{entity_name(source)}" unless copy&.valid?

    copy.make_unique if copy.respond_to?(:make_unique)
    copy.name = "#{entity_name(source)} [LVN V6 REGRESSION TEMP]"
    model.commit_operation
    started = false
    copy
  rescue StandardError
    model.abort_operation if started
    raise
  end

  def remove_copy(model, copy)
    return nil unless copy&.valid?

    started = model.start_operation('Remove LVN v6 regression copy', true)
    raise 'Could not start LVN v6 regression cleanup operation' unless started

    model.entities.erase_entities(copy)
    model.commit_operation
    started = false
    nil
  rescue StandardError => error
    model.abort_operation if started
    puts "[LVN V6 REGRESSION] WARNING cleanup failed: #{error.class}: #{error.message}"
    nil
  end

  def entity_snapshot(entity)
    return nil unless entity&.valid?
    return nil unless entity.respond_to?(:definition) && entity.definition

    entities = entity.definition.entities
    faces = entities.grep(Sketchup::Face)
    edges = entities.grep(Sketchup::Edge)
    vertices = edges.flat_map { |edge| [edge.start, edge.end] }.uniq

    {
      valid: entity.valid?,
      manifold: safe_manifold(entity),
      faces: faces.length,
      edges: edges.length,
      vertices: vertices.length,
      volume_mm3: safe_volume_mm3(entity)
    }
  rescue StandardError => error
    { snapshot_error: "#{error.class}: #{error.message}" }
  end

  def geometry_counts_changed?(before, after, success)
    return nil unless success && before && after
    return nil if before[:snapshot_error] || after[:snapshot_error]

    %i[faces edges vertices].any? { |key| before[key] != after[key] }
  end

  def compact_normalization_report(report)
    return nil unless report.is_a?(Hash)

    keys = %i[
      topology_before topology_after volume_before_mm3 volume_after_mm3 residual_mm
      mesh_validation final_mesh_validation final_surface_equivalence snapshot_reuse
      axis_plane_merge short_edge_sliver_repair source_boundary_normalization
      source_altitude_sliver_collapse duplicate_diagnostics degenerate_repair
    ]

    sanitize(keys.each_with_object({}) do |key, output|
      output[key] = report[key] if report.key?(key)
    end)
  end

  def build_summary(results, selected_count, solid_count, started_at, finished_at, tolerance_mm)
    successes = results.select { |result| result[:success] }
    failures = results.reject { |result| result[:success] }
    regressions = results.select { |result| result[:regression] }

    {
      schema: 'ulol.lvn_v6_regression.v2',
      generated_at: finished_at.iso8601(3),
      elapsed_sec: finished_at - started_at,
      tolerance_mm: tolerance_mm,
      selected_count: selected_count,
      solid_count: solid_count,
      success_count: successes.length,
      failure_count: failures.length,
      previous_success_regression_count: regressions.length,
      target_unresolved_count: results.count { |result| result[:target_unresolved] },
      geometry_counts_changed_success_count: successes.count { |result| result[:geometry_counts_changed] == true },
      accepted_repair_solid_count: results.count { |result| result.dig(:stitch_report, 'accepted_stitch_count').to_i.positive? },
      total_initial_invalid_pairs: results.sum { |result| result.dig(:stitch_report, 'initial_invalid_pair_count').to_i },
      total_final_invalid_pairs: results.sum { |result| result.dig(:stitch_report, 'final_invalid_pair_count').to_i },
      regressions: regressions.map { |result| failure_summary(result) },
      failures: failures.map { |result| failure_summary(result) },
      results: results
    }
  end

  def failure_summary(result)
    {
      pid: result[:source_pid],
      name: result[:source_name],
      baseline_status: result[:baseline_status],
      error_class: result[:error_class],
      error_message: result[:error_message]
    }
  end

  def write_report(summary)
    FileUtils.mkdir_p(REPORT_DIR)
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    path = File.join(REPORT_DIR, "lvn_v6_regression_#{timestamp}.json")
    File.write(path, JSON.pretty_generate(sanitize(summary)))
    path
  end

  def print_result(result)
    state = result[:regression] ? 'REGRESSION' : (result[:success] ? 'OK' : 'FAIL')
    report = result[:stitch_report] || {}

    puts '-' * 110
    puts format('[LVN V6] %3d/%3d %-10s %s', result[:index], result[:total], state, result[:source_name])
    puts format(
      '  invalid=%s -> %s reduction=%s stitches=%s low=%s->%s',
      report['initial_invalid_pair_count'].inspect,
      report['final_invalid_pair_count'].inspect,
      report['invalid_pair_reduction'].inspect,
      report['accepted_stitch_count'].inspect,
      report['initial_low_altitude_count'].inspect,
      report['final_low_altitude_count'].inspect
    )
    puts "  geometry_counts_changed=#{result[:geometry_counts_changed].inspect}"
    puts "  error=#{result[:error_class]}: #{result[:error_message]}" unless result[:success]
  end

  def print_summary(summary)
    puts
    puts '=' * 110
    puts '[LVN V6 REGRESSION SUMMARY]'
    puts "solids=#{summary[:solid_count]} success=#{summary[:success_count]} failure=#{summary[:failure_count]}"
    puts "previous-success regressions=#{summary[:previous_success_regression_count]}"
    puts "target unresolved=#{summary[:target_unresolved_count]}"
    puts "successful solids with geometry-count change=#{summary[:geometry_counts_changed_success_count]}"
    puts "solids using accepted v6 repair=#{summary[:accepted_repair_solid_count]}"
    puts "total exact invalid pairs=#{summary[:total_initial_invalid_pairs]} -> #{summary[:total_final_invalid_pairs]}"
    puts "report=#{summary[:report_path]}"

    if summary[:solid_count] == 159 && summary[:success_count] == 158 && summary[:failure_count] == 1 &&
       summary[:previous_success_regression_count].zero? && summary[:target_unresolved_count].zero?
      puts 'RESULT: PASS CANDIDATE'
    elsif summary[:previous_success_regression_count].positive?
      puts 'RESULT: REGRESSION DETECTED'
    else
      puts 'RESULT: REVIEW REQUIRED'
    end
    puts '=' * 110
  end

  def manifold_solid?(entity)
    entity&.valid? && entity.respond_to?(:definition) && entity.respond_to?(:manifold?) && entity.manifold? == true
  rescue StandardError
    false
  end

  def safe_manifold(entity)
    entity.manifold?
  rescue StandardError
    nil
  end

  def safe_volume_mm3(entity)
    entity.volume.to_f * (25.4**3)
  rescue StandardError
    nil
  end

  def safe_pid(entity)
    entity.persistent_id
  rescue StandardError
    nil
  end

  def entity_name(entity)
    name = entity.respond_to?(:name) ? entity.name.to_s : ''
    return name unless name.empty?

    definition_name = entity.respond_to?(:definition) && entity.definition ? entity.definition.name.to_s : ''
    return definition_name unless definition_name.empty?

    entity.class.to_s
  rescue StandardError
    entity.class.to_s
  end

  def sanitize(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, child), output| output[key.to_s] = sanitize(child) }
    when Array
      value.map { |child| sanitize(child) }
    when Symbol
      value.to_s
    when Time
      value.iso8601(3)
    when Numeric, String, TrueClass, FalseClass, NilClass
      value
    else
      value.to_s
    end
  end
end

nil
