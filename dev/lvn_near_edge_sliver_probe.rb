# frozen_string_literal: true

# Focused diagnostic for near-edge sliver stitch feasibility.
#
# SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_near_edge_sliver_probe.rb'
# LvnNearEdgeSliverProbe.run
#
# This script never commits normalization changes. It reuses the hard-gate deep
# probe, which always aborts its SketchUp operation, and only post-processes the
# in-memory hard-gate triangle snapshot.

require 'json'
require 'tmpdir'
require 'time'
require_relative 'lvn_hard_gate_deep_probe'

module LvnNearEdgeSliverProbe
  TARGET_PID = 2_240_496
  TARGET_LABEL = 'op08xapo'
  FOCUS_PAIR = [180, 689].freeze

  LVN = LvnHardGateDeepProbe::LVN
  GRID_MM = LVN::DEFAULT_TOLERANCE_MM
  MAX_NEAR_EDGE_DISTANCE_MM = GRID_MM

  module_function

  def run(mode: :normal)
    mode = mode.to_sym
    unless LvnHardGateDeepProbe::NORMALIZATION_MODES.include?(mode)
      raise ArgumentError,
            "mode must be one of #{LvnHardGateDeepProbe::NORMALIZATION_MODES.inspect}: #{mode.inspect}"
    end

    model = Sketchup.active_model
    entity = LvnHardGateDeepProbe.find_entity(model, TARGET_PID)
    unless entity&.respond_to?(:valid?) && entity.valid?
      raise "Target not found: #{TARGET_LABEL} PID=#{TARGET_PID}"
    end

    model.selection.clear
    model.selection.add(entity)

    analysis = LvnHardGateDeepProbe.analyze_entity(
      model,
      entity,
      TARGET_PID,
      TARGET_LABEL,
      mode
    )
    result = build_result(analysis)
    path = File.join(
      Dir.tmpdir,
      "lvn_near_edge_sliver_probe_#{TARGET_LABEL}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
    )
    File.open(path, 'w:UTF-8') do |file|
      file.write(JSON.pretty_generate(json_safe(result)))
    end
    result[:json_path] = path

    $lvn_near_edge_sliver_probe = result
    print_summary(result)
    puts "\n[LVN NEAR-EDGE SLIVER] JSON: #{path}"
    puts '[LVN NEAR-EDGE SLIVER] Full result: $lvn_near_edge_sliver_probe'
    result
  end

  def build_result(analysis)
    probe = analysis.fetch(:probe)
    hard = Array(probe[:stages]).find { |stage| stage[:name] == :hard_gate }
    raise 'Hard-gate snapshot was not captured' unless hard

    records = hard.fetch(:triangles)
    inventory = edge_inventory(records)
    pair_analyses = Array(probe[:pair_analyses])

    pair_results = pair_analyses.map do |pair|
      build_pair_result(pair, records, inventory)
    end
    focus = pair_results.find { |pair| pair[:indices].sort == FOCUS_PAIR.sort }

    {
      schema: 'ulol.lvn_near_edge_sliver_probe.v1',
      generated_at: Time.now.iso8601(3),
      target: {
        pid: TARGET_PID,
        label: TARGET_LABEL,
        name: analysis[:name]
      },
      normalization_mode: analysis[:normalization_mode],
      normalization_error: analysis[:normalization_error],
      operation_started: analysis[:operation_started],
      operation_aborted: analysis[:operation_aborted],
      grid_mm: GRID_MM,
      max_near_edge_distance_mm: MAX_NEAR_EDGE_DISTANCE_MM,
      hard_gate: probe[:hard_gate],
      focus_pair: FOCUS_PAIR,
      focus_pair_found: !focus.nil?,
      focus_pair_analysis: focus,
      invalid_pair_count: pair_results.length,
      pairs_with_near_edge_candidate_count:
        pair_results.count { |pair| !pair[:near_edge_candidates].empty? },
      near_edge_candidate_count:
        pair_results.sum { |pair| pair[:near_edge_candidates].length },
      pair_analyses: pair_results
    }
  end

  def build_pair_result(pair, records, inventory)
    candidates = Array(pair[:edge_split_analysis]).filter_map do |entry|
      build_candidate(entry, records, inventory)
    end
    candidates.sort_by! do |candidate|
      [
        candidate[:distance_to_segment_mm],
        candidate[:naive_short_edge_overincidence_count],
        candidate[:owner_triangle],
        candidate[:candidate_triangle],
        candidate[:edge_index],
        candidate[:candidate_vertex_index]
      ]
    end

    {
      indices: pair[:indices],
      plane_relation: pair.dig(:exact_intersection, :plane_relation),
      exact_intersection: pair[:exact_intersection],
      near_edge_candidates: candidates,
      best_near_edge_candidate: candidates.first
    }
  end

  def build_candidate(entry, records, inventory)
    return nil if entry[:exact_collinear]

    edge = entry.fetch(:edge)
    point = entry.fetch(:candidate_vertex)
    projection = projection_parameter(point, edge)
    return nil unless projection[:strictly_inside]

    distance_mm = point_line_distance_mm(point, edge)
    return nil if distance_mm > MAX_NEAR_EDGE_DISTANCE_MM

    start_point, end_point = edge
    host_edge = canonical_edge(start_point, end_point)
    short_a = canonical_edge(start_point, point)
    short_b = canonical_edge(point, end_point)
    lengths = {
      host_edge_mm: grid_distance_mm(start_point, end_point),
      start_to_vertex_mm: grid_distance_mm(start_point, point),
      vertex_to_end_mm: grid_distance_mm(point, end_point)
    }
    longest = lengths.max_by { |_name, length| length }&.first
    normal = integer_cross(
      integer_subtract(end_point, start_point),
      integer_subtract(point, start_point)
    )

    host_owners = Array(inventory[host_edge])
    short_a_owners = Array(inventory[short_a])
    short_b_owners = Array(inventory[short_b])
    overincidence_count = [short_a_owners, short_b_owners].count { |owners| owners.length >= 2 }

    {
      owner_triangle: entry[:owner_triangle],
      candidate_triangle: entry[:candidate_triangle],
      edge_index: entry[:edge_index],
      candidate_vertex_index: entry[:candidate_vertex_index],
      host_edge: host_edge,
      penetrating_vertex: point,
      replacement_short_edges: [short_a, short_b],
      projection_parameter: rational_hash(projection[:parameter]),
      projection_numerator: projection[:numerator],
      projection_denominator: projection[:denominator],
      projection_strictly_inside: true,
      distance_to_infinite_line_mm: distance_mm,
      distance_to_segment_mm: distance_mm,
      distance_as_grid_fraction: distance_mm / GRID_MM,
      sliver_altitude_mm: sliver_altitude_mm(start_point, end_point, point),
      sliver_exact_non_degenerate: normal.any? { |value| !value.zero? },
      sliver_integer_normal: normal,
      edge_lengths_mm: lengths,
      host_edge_is_longest: longest == :host_edge_mm,
      longest_edge: longest,
      edge_incidence: {
        host_edge: host_owners.length,
        start_to_vertex: short_a_owners.length,
        vertex_to_end: short_b_owners.length
      },
      edge_owners: {
        host_edge: owner_summaries(records, host_owners),
        start_to_vertex: owner_summaries(records, short_a_owners),
        vertex_to_end: owner_summaries(records, short_b_owners)
      },
      vertex_one_rings: {
        host_start: vertex_one_ring(records, start_point),
        host_end: vertex_one_ring(records, end_point),
        penetrating_vertex: vertex_one_ring(records, point)
      },
      provenance_relation: provenance_relation(records, host_owners),
      naive_short_edge_overincidence_count: overincidence_count,
      naive_add_would_overincide: overincidence_count.positive?,
      needs_patch_retriangulation: true,
      classification:
        'near-edge non-collinear grid vertex; candidate for local sliver-stitch retriangulation'
    }
  end

  def edge_inventory(records)
    inventory = Hash.new { |hash, key| hash[key] = [] }
    records.each_with_index do |record, triangle_index|
      points = record.fetch(:points_source_or_grid)
      3.times do |edge_index|
        key = canonical_edge(points[edge_index], points[(edge_index + 1) % 3])
        inventory[key] << triangle_index
      end
    end
    inventory
  end

  def owner_summaries(records, indices)
    indices.map do |triangle_index|
      record = records.fetch(triangle_index)
      {
        triangle_index: triangle_index,
        source_face_key: record[:source_face_key],
        source_polygon_index: record[:source_polygon_index],
        points: record[:points_source_or_grid]
      }
    end
  end

  def vertex_one_ring(records, vertex)
    records.each_with_index.filter_map do |record, triangle_index|
      next unless record.fetch(:points_source_or_grid).include?(vertex)

      {
        triangle_index: triangle_index,
        source_face_key: record[:source_face_key],
        source_polygon_index: record[:source_polygon_index],
        points: record[:points_source_or_grid]
      }
    end
  end

  def provenance_relation(records, owner_indices)
    owners = owner_summaries(records, owner_indices)
    face_keys = owners.map { |owner| owner[:source_face_key] }.compact.uniq
    polygon_indices = owners.map { |owner| owner[:source_polygon_index] }.compact.uniq
    {
      owner_count: owners.length,
      unique_source_face_keys: face_keys,
      unique_source_polygon_indices: polygon_indices,
      same_source_face: owners.length >= 2 && face_keys.length == 1,
      same_source_polygon: owners.length >= 2 && polygon_indices.length == 1
    }
  end

  def projection_parameter(point, edge)
    start_point, end_point = edge
    direction = integer_subtract(end_point, start_point)
    offset = integer_subtract(point, start_point)
    denominator = integer_dot(direction, direction)
    raise 'Zero-length host edge in hard-gate snapshot' unless denominator.positive?

    numerator = integer_dot(offset, direction)
    {
      numerator: numerator,
      denominator: denominator,
      parameter: Rational(numerator, denominator),
      strictly_inside: numerator.positive? && numerator < denominator
    }
  end

  def point_line_distance_mm(point, edge)
    start_point, end_point = edge
    direction = integer_subtract(end_point, start_point)
    offset = integer_subtract(point, start_point)
    cross = integer_cross(direction, offset)
    direction_length = Math.sqrt(integer_dot(direction, direction))
    return Float::INFINITY if direction_length.zero?

    Math.sqrt(integer_dot(cross, cross)) / direction_length * GRID_MM
  end

  def sliver_altitude_mm(start_point, end_point, apex)
    point_line_distance_mm(apex, [start_point, end_point])
  end

  def grid_distance_mm(point_a, point_b)
    delta = integer_subtract(point_b, point_a)
    Math.sqrt(integer_dot(delta, delta)) * GRID_MM
  end

  def canonical_edge(point_a, point_b)
    (point_a <=> point_b) <= 0 ? [point_a, point_b] : [point_b, point_a]
  end

  def integer_subtract(vector_a, vector_b)
    [
      vector_a[0] - vector_b[0],
      vector_a[1] - vector_b[1],
      vector_a[2] - vector_b[2]
    ]
  end

  def integer_dot(vector_a, vector_b)
    (vector_a[0] * vector_b[0]) +
      (vector_a[1] * vector_b[1]) +
      (vector_a[2] * vector_b[2])
  end

  def integer_cross(vector_a, vector_b)
    [
      (vector_a[1] * vector_b[2]) - (vector_a[2] * vector_b[1]),
      (vector_a[2] * vector_b[0]) - (vector_a[0] * vector_b[2]),
      (vector_a[0] * vector_b[1]) - (vector_a[1] * vector_b[0])
    ]
  end

  def rational_hash(value)
    { numerator: value.numerator, denominator: value.denominator }
  end

  def json_safe(value)
    case value
    when Rational
      rational_hash(value)
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

  def print_summary(result)
    puts "\n#{'=' * 100}"
    puts '[LVN NEAR-EDGE SLIVER PROBE]'
    puts "target=#{result.dig(:target, :label)} pid=#{result.dig(:target, :pid)} " \
         "name=#{result.dig(:target, :name).inspect}"
    puts "mode=#{result[:normalization_mode]} operation_aborted=#{result[:operation_aborted]}"
    puts "invalid_pairs=#{result[:invalid_pair_count]} " \
         "pairs_with_candidate=#{result[:pairs_with_near_edge_candidate_count]} " \
         "candidates=#{result[:near_edge_candidate_count]}"

    focus = result[:focus_pair_analysis]
    unless focus
      puts "\n[FOCUS] T#{FOCUS_PAIR[0]}/T#{FOCUS_PAIR[1]} not present at hard gate"
      puts '=' * 100
      return
    end

    puts "\n[FOCUS] T#{FOCUS_PAIR[0]} x T#{FOCUS_PAIR[1]}"
    puts "  plane_relation=#{focus[:plane_relation]}"
    candidate = focus[:best_near_edge_candidate]
    unless candidate
      puts '  no near-edge sliver candidate within one grid spacing'
      puts '=' * 100
      return
    end

    puts "  owner_triangle=T#{candidate[:owner_triangle]} " \
         "candidate_triangle=T#{candidate[:candidate_triangle]}"
    puts "  host_edge=#{candidate[:host_edge].inspect}"
    puts "  penetrating_vertex=#{candidate[:penetrating_vertex].inspect}"
    puts format(
      '  distance=%.12f mm (%.6f grid), altitude=%.12f mm',
      candidate[:distance_to_segment_mm],
      candidate[:distance_as_grid_fraction],
      candidate[:sliver_altitude_mm]
    )
    puts "  edge_lengths_mm=#{candidate[:edge_lengths_mm].inspect}"
    puts "  host_edge_is_longest=#{candidate[:host_edge_is_longest]}"
    puts "  incidence=#{candidate[:edge_incidence].inspect}"
    puts "  provenance=#{candidate[:provenance_relation].inspect}"
    puts "  naive_add_would_overincide=#{candidate[:naive_add_would_overincide]}"
    puts '  NOTE: this probe does not mutate or repair the mesh.'
    puts '=' * 100
  end
end
