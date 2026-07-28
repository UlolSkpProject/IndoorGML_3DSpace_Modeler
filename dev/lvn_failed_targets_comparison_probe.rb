# frozen_string_literal: true

# Compares the current failing LVN targets with the same deep diagnostic format.
# Every normalization attempt runs inside its own SketchUp operation and is
# always aborted by LvnHardGateDeepProbe.analyze_entity.
#
# SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_failed_targets_comparison_probe.rb'
# LvnFailedTargetsComparisonProbe.run

require 'json'
require 'tmpdir'
require 'time'
require_relative 'lvn_near_edge_sliver_probe'

module LvnFailedTargetsComparisonProbe
  Deep = LvnHardGateDeepProbe
  Near = LvnNearEdgeSliverProbe
  LVN = Deep::LVN

  TARGETS = [
    {
      pid: 1_189_788,
      label: 'ijn58ryq',
      expected_name: '[TransitionSpace:Stair]-ijn58ryq',
      scan_pair: [152, 164]
    },
    {
      pid: 1_106_041,
      label: 's8vadud8',
      expected_name: '[GeneralSpace:Room]-s8vadud8',
      scan_pair: [180, 689]
    },
    {
      pid: 1_107_846,
      label: 'o6rz6ds0',
      expected_name: '[GeneralSpace:Room]-o6rz6ds0',
      scan_pair: [251, 851]
    }
  ].freeze

  STAGES_OF_INTEREST = [:grid_normalized, :grid_conforming, :hard_gate].freeze

  module_function

  def run(mode: :normal)
    mode = mode.to_sym
    unless Deep::NORMALIZATION_MODES.include?(mode)
      raise ArgumentError,
            "mode must be one of #{Deep::NORMALIZATION_MODES.inspect}: #{mode.inspect}"
    end

    model = Sketchup.active_model
    result = {
      schema: 'ulol.lvn_failed_targets_comparison_probe.v1',
      generated_at: Time.now.iso8601(3),
      normalization_mode: mode,
      grid_mm: LVN::DEFAULT_TOLERANCE_MM,
      targets: TARGETS,
      entities: []
    }

    TARGETS.each_with_index do |target, index|
      entity = Deep.find_entity(model, target[:pid])
      unless entity&.respond_to?(:valid?) && entity.valid?
        result[:entities] << {
          target: target,
          status: 'NOT_FOUND'
        }
        warn "[LVN FAILED TARGETS] not found: #{target[:label]} PID=#{target[:pid]}"
        next
      end

      puts "\n[LVN FAILED TARGETS] #{index + 1}/#{TARGETS.length} #{target[:label]} PID=#{target[:pid]}"
      analysis = Deep.analyze_entity(
        model,
        entity,
        target[:pid],
        target[:label],
        mode
      )
      comparison = build_entity_result(target, analysis)
      result[:entities] << comparison
      print_entity_summary(comparison)
    rescue StandardError => error
      result[:entities] << {
        target: target,
        status: 'PROBE_ERROR',
        error: "#{error.class}: #{error.message}",
        backtrace: Array(error.backtrace).first(20)
      }
      warn "[LVN FAILED TARGETS] #{target[:label]} probe error: #{error.class}: #{error.message}"
    end

    result[:summary] = build_global_summary(result[:entities])

    path = File.join(
      Dir.tmpdir,
      "lvn_failed_targets_comparison_probe_#{mode}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
    )
    File.open(path, 'w:UTF-8') { |file| file.write(JSON.pretty_generate(json_safe(result))) }
    result[:json_path] = path
    $lvn_failed_targets_comparison_probe = result

    print_global_summary(result)
    puts "\n[LVN FAILED TARGETS] JSON: #{path}"
    puts '[LVN FAILED TARGETS] Full result: $lvn_failed_targets_comparison_probe'
    result
  end

  def build_entity_result(target, analysis)
    probe = analysis.fetch(:probe)
    hard_stage = Array(probe[:stages]).find { |stage| stage[:name] == :hard_gate }
    hard_records = hard_stage ? hard_stage.fetch(:triangles) : []
    inventory = Near.edge_inventory(hard_records)

    pair_results = Array(probe[:pair_analyses]).map do |pair|
      Near.build_pair_result(pair, hard_records, inventory)
    end

    focus_pair = pair_results.find do |pair|
      pair[:indices].sort == target[:scan_pair].sort
    end

    stage_summaries = STAGES_OF_INTEREST.map do |stage_name|
      build_stage_summary(probe, stage_name)
    end

    all_candidates = pair_results.flat_map { |pair| Array(pair[:near_edge_candidates]) }
    best_candidates = pair_results.filter_map { |pair| pair[:best_near_edge_candidate] }

    {
      target: target,
      status: 'ANALYZED',
      actual_name: analysis[:name],
      name_matches_expected: analysis[:name].to_s == target[:expected_name],
      normalization_error: analysis[:normalization_error],
      operation_started: analysis[:operation_started],
      operation_aborted: analysis[:operation_aborted],
      first_invalid_intersection_stage: probe[:first_invalid_intersection_stage],
      stage_summaries: stage_summaries,
      hard_gate: probe[:hard_gate],
      scan_pair: target[:scan_pair],
      scan_pair_found: !focus_pair.nil?,
      scan_pair_analysis: focus_pair,
      invalid_pair_count: pair_results.length,
      pairs_with_near_edge_candidate_count:
        pair_results.count { |pair| !pair[:near_edge_candidates].empty? },
      near_edge_candidate_count: all_candidates.length,
      unique_near_edge_relation_count: unique_candidate_relations(all_candidates).length,
      unique_near_edge_relations: unique_candidate_relations(all_candidates),
      closest_candidate: best_candidates.min_by { |candidate| candidate[:distance_to_segment_mm] },
      pair_analyses: pair_results,
      conclusions: probe[:conclusions]
    }
  end

  def build_stage_summary(probe, stage_name)
    stage = Array(probe[:stages]).find { |entry| entry[:name] == stage_name }
    intersection = Array(probe[:stage_intersections]).find do |entry|
      entry[:stage] == stage_name
    end

    return {
      stage: stage_name,
      reached: false
    } unless stage

    triangles = stage[:triangles].map { |record| record[:points_source_or_grid] }
    valid_triangles = triangles.reject do |triangle|
      triangle.uniq.length != 3 || integer_zero_normal?(triangle)
    end

    normalizer = Deep::ProbeNormalizer.new(LVN::DEFAULT_TOLERANCE_MM)
    topology = normalizer.send(:topology_summary, valid_triangles)

    {
      stage: stage_name,
      reached: true,
      triangle_count: triangles.length,
      valid_triangle_count: valid_triangles.length,
      skipped_degenerate_triangle_count: triangles.length - valid_triangles.length,
      topology: topology,
      intersection: intersection || {
        stage: stage_name,
        analysis_missing: true
      }
    }
  rescue StandardError => error
    {
      stage: stage_name,
      reached: !stage.nil?,
      analysis_error: "#{error.class}: #{error.message}"
    }
  end

  def integer_zero_normal?(triangle)
    a, b, c = triangle
    ab = [b[0] - a[0], b[1] - a[1], b[2] - a[2]]
    ac = [c[0] - a[0], c[1] - a[1], c[2] - a[2]]
    normal = [
      (ab[1] * ac[2]) - (ab[2] * ac[1]),
      (ab[2] * ac[0]) - (ab[0] * ac[2]),
      (ab[0] * ac[1]) - (ab[1] * ac[0])
    ]
    normal.all?(&:zero?)
  end

  def unique_candidate_relations(candidates)
    grouped = {}
    candidates.each do |candidate|
      key = [candidate[:host_edge], candidate[:penetrating_vertex]]
      entry = grouped[key] ||= {
        host_edge: candidate[:host_edge],
        penetrating_vertex: candidate[:penetrating_vertex],
        count: 0,
        minimum_distance_mm: candidate[:distance_to_segment_mm],
        minimum_grid_fraction: candidate[:distance_as_grid_fraction],
        host_edge_incidence: candidate.dig(:edge_incidence, :host_edge),
        short_edge_incidences: [
          candidate.dig(:edge_incidence, :start_to_vertex),
          candidate.dig(:edge_incidence, :vertex_to_end)
        ],
        same_source_face: candidate.dig(:provenance_relation, :same_source_face),
        naive_add_would_overincide: candidate[:naive_add_would_overincide]
      }
      entry[:count] += 1
      entry[:minimum_distance_mm] = [
        entry[:minimum_distance_mm],
        candidate[:distance_to_segment_mm]
      ].min
      entry[:minimum_grid_fraction] = [
        entry[:minimum_grid_fraction],
        candidate[:distance_as_grid_fraction]
      ].min
      entry[:naive_add_would_overincide] ||= candidate[:naive_add_would_overincide]
    end
    grouped.values.sort_by { |entry| [entry[:minimum_distance_mm], -entry[:count]] }
  end

  def build_global_summary(entities)
    analyzed = entities.select { |entry| entry[:status] == 'ANALYZED' }
    {
      target_count: TARGETS.length,
      analyzed_count: analyzed.length,
      not_found_count: entities.count { |entry| entry[:status] == 'NOT_FOUND' },
      probe_error_count: entities.count { |entry| entry[:status] == 'PROBE_ERROR' },
      hard_gate_invalid_pair_counts: analyzed.to_h do |entry|
        [entry.dig(:target, :label), entry[:invalid_pair_count]]
      end,
      near_edge_coverage: analyzed.to_h do |entry|
        invalid = entry[:invalid_pair_count].to_i
        covered = entry[:pairs_with_near_edge_candidate_count].to_i
        [
          entry.dig(:target, :label),
          {
            invalid_pairs: invalid,
            pairs_with_candidate: covered,
            all_pairs_covered: invalid.positive? && invalid == covered
          }
        ]
      end
    }
  end

  def print_entity_summary(result)
    puts "  name=#{result[:actual_name].inspect} expected_match=#{result[:name_matches_expected]}"
    puts "  first_invalid_stage=#{result[:first_invalid_intersection_stage].inspect}"
    result[:stage_summaries].each do |stage|
      unless stage[:reached]
        puts "  #{stage[:stage]}: NOT_REACHED"
        next
      end
      if stage[:analysis_error]
        puts "  #{stage[:stage]}: ANALYSIS_ERROR #{stage[:analysis_error]}"
        next
      end
      puts "  #{stage[:stage]}: triangles=#{stage[:triangle_count]} " \
           "topology=#{stage.dig(:topology, :status)} " \
           "invalid_pairs=#{stage.dig(:intersection, :invalid_pair_count)}"
    end
    puts "  hard_gate_invalid_pairs=#{result[:invalid_pair_count]}"
    puts "  near_edge_coverage=#{result[:pairs_with_near_edge_candidate_count]}/#{result[:invalid_pair_count]} " \
         "candidates=#{result[:near_edge_candidate_count]} " \
         "unique_relations=#{result[:unique_near_edge_relation_count]}"
    if result[:closest_candidate]
      candidate = result[:closest_candidate]
      puts "  closest_near_edge=#{candidate[:distance_to_segment_mm]} mm " \
           "(#{candidate[:distance_as_grid_fraction]} grid)"
    end
    puts "  scan_pair=#{result[:scan_pair].inspect} found=#{result[:scan_pair_found]}"
  end

  def print_global_summary(result)
    summary = result[:summary]
    puts "\n#{'=' * 100}"
    puts '[LVN FAILED TARGETS COMPARISON RESULT]'
    puts "targets=#{summary[:target_count]} analyzed=#{summary[:analyzed_count]} " \
         "not_found=#{summary[:not_found_count]} probe_errors=#{summary[:probe_error_count]}"
    result[:entities].each do |entry|
      target = entry[:target] || {}
      if entry[:status] == 'ANALYZED'
        puts "  #{target[:label]} PID=#{target[:pid]}: invalid=#{entry[:invalid_pair_count]} " \
             "near_edge=#{entry[:pairs_with_near_edge_candidate_count]}/#{entry[:invalid_pair_count]} " \
             "first=#{entry[:first_invalid_intersection_stage].inspect}"
      else
        puts "  #{target[:label]} PID=#{target[:pid]}: #{entry[:status]} #{entry[:error]}"
      end
    end
    puts '=' * 100
  end

  def json_safe(value)
    case value
    when Rational
      { numerator: value.numerator, denominator: value.denominator }
    when Hash
      value.each_with_object({}) do |(key, item), output|
        output[key] = json_safe(item)
      end
    when Array
      value.map { |item| json_safe(item) }
    when Symbol
      value.to_s
    when Float
      value.finite? ? value : value.to_s
    else
      value
    end
  end
end
