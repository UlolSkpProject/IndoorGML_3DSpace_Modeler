# frozen_string_literal: true

# Simulates a topology-preserving retriangulation of the snapped source face
# implicated by the T180/T689 near-edge conflict. No SketchUp geometry is kept:
# the underlying deep probe always aborts its operation.
#
# SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_grid_face_retriangulation_probe.rb'
# LvnGridFaceRetriangulationProbe.run

require 'json'
require 'tmpdir'
require 'time'
require_relative 'lvn_near_edge_sliver_probe'

module LvnGridFaceRetriangulationProbe
  TARGET_PID = 2_240_496
  TARGET_LABEL = 'op08xapo'
  FOCUS_PAIR = [180, 689].freeze

  Deep = LvnHardGateDeepProbe
  Near = LvnNearEdgeSliverProbe
  LVN = Deep::LVN

  module_function

  def run(mode: :normal)
    mode = mode.to_sym
    unless Deep::NORMALIZATION_MODES.include?(mode)
      raise ArgumentError,
            "mode must be one of #{Deep::NORMALIZATION_MODES.inspect}: #{mode.inspect}"
    end

    model = Sketchup.active_model
    entity = Deep.find_entity(model, TARGET_PID)
    unless entity&.respond_to?(:valid?) && entity.valid?
      raise "Target not found: #{TARGET_LABEL} PID=#{TARGET_PID}"
    end

    model.selection.clear
    model.selection.add(entity)

    analysis = Deep.analyze_entity(model, entity, TARGET_PID, TARGET_LABEL, mode)
    result = simulate(analysis)

    path = File.join(
      Dir.tmpdir,
      "lvn_grid_face_retriangulation_probe_#{TARGET_LABEL}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
    )
    File.open(path, 'w:UTF-8') { |file| file.write(JSON.pretty_generate(json_safe(result))) }
    result[:json_path] = path
    $lvn_grid_face_retriangulation_probe = result

    print_summary(result)
    puts "\n[LVN GRID FACE RETRIANGULATION] JSON: #{path}"
    puts '[LVN GRID FACE RETRIANGULATION] Full result: $lvn_grid_face_retriangulation_probe'
    result
  end

  def simulate(analysis)
    probe = analysis.fetch(:probe)
    hard = Array(probe[:stages]).find { |stage| stage[:name] == :hard_gate }
    raise 'Hard-gate snapshot was not captured' unless hard

    records = hard.fetch(:triangles)
    near = Near.build_result(analysis)
    focus = near[:focus_pair_analysis]
    raise "Focus pair not found: #{FOCUS_PAIR.inspect}" unless focus

    candidate = focus[:best_near_edge_candidate]
    raise 'Focus pair has no near-edge candidate' unless candidate

    face_keys = Array(candidate.dig(:provenance_relation, :unique_source_face_keys))
    unless face_keys.length == 1
      raise "Focus host edge is not internal to one source face: #{face_keys.inspect}"
    end
    source_face_key = face_keys.first

    face_records = records.select { |record| record[:source_face_key] == source_face_key }
    raise "No triangles for source_face_key=#{source_face_key}" if face_records.empty?

    face_inventory = edge_inventory(face_records)
    boundary_edges = face_inventory.select { |_edge, owners| owners.length == 1 }.keys
    internal_edges = face_inventory.select { |_edge, owners| owners.length == 2 }.keys
    overused_edges = face_inventory.select { |_edge, owners| owners.length > 2 }

    loops_report = boundary_loops(boundary_edges)
    base = {
      schema: 'ulol.lvn_grid_face_retriangulation_probe.v1',
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
      baseline: {
        triangle_count: records.length,
        topology: probe.dig(:hard_gate, :topology),
        geometry: probe.dig(:hard_gate, :geometry)
      },
      focus_pair: FOCUS_PAIR,
      focus_candidate: candidate,
      source_face_key: source_face_key,
      source_face_triangle_count: face_records.length,
      source_face_vertex_count: face_records.flat_map { |record| record[:points_source_or_grid] }.uniq.length,
      source_face_edge_count: face_inventory.length,
      source_face_boundary_edge_count: boundary_edges.length,
      source_face_internal_edge_count: internal_edges.length,
      source_face_overused_edge_count: overused_edges.length,
      source_face_overused_edges: overused_edges.map { |edge, owners| { edge: edge, owner_count: owners.length } },
      boundary: loops_report
    }

    unless overused_edges.empty?
      return base.merge(simulation: unsupported('source-face local edge incidence exceeds 2'))
    end
    unless loops_report[:valid_degree_two]
      return base.merge(simulation: unsupported('source-face boundary graph is not degree-2'))
    end
    unless loops_report[:loops].length == 1
      return base.merge(
        simulation: unsupported(
          "source-face has #{loops_report[:loops].length} boundary loops; hole-aware triangulation not enabled"
        )
      )
    end

    loop_points = loops_report[:loops].first
    plane = exact_plane(loop_points, face_records)
    unless plane[:coplanar]
      return base.merge(simulation: unsupported('snapped source-face vertices are not exactly coplanar'), plane: plane)
    end

    self_intersections = polygon_self_intersections(loop_points, plane[:drop_axis])
    unless self_intersections.empty?
      return base.merge(
        plane: plane,
        simulation: unsupported('source-face boundary loop self-intersects after snapping'),
        boundary_self_intersections: self_intersections
      )
    end

    triangulation = ear_clip(loop_points, plane[:drop_axis], plane[:normal])
    unless triangulation[:ok]
      return base.merge(plane: plane, simulation: unsupported(triangulation[:reason]), triangulation: triangulation)
    end

    new_face_triangles = triangulation[:triangles]
    new_boundary = edge_inventory_from_triangles(new_face_triangles)
      .select { |_edge, owners| owners.length == 1 }.keys.sort
    boundary_preserved = new_boundary == boundary_edges.sort

    simulated_records = records.reject { |record| record[:source_face_key] == source_face_key }
      .map { |record| record[:points_source_or_grid] }
    simulated_records.concat(new_face_triangles)

    normalizer = Deep::ProbeNormalizer.new(LVN::DEFAULT_TOLERANCE_MM)
    topology = normalizer.send(:topology_summary, simulated_records)
    failures = normalizer.send(:collect_triangle_intersection_failures, simulated_records)

    simulation = {
      status: 'SIMULATED',
      source_face_triangle_count_before: face_records.length,
      source_face_triangle_count_after: new_face_triangles.length,
      source_face_boundary_preserved: boundary_preserved,
      source_face_boundary_edge_count_after: new_boundary.length,
      total_triangle_count_after: simulated_records.length,
      topology: topology,
      geometry: {
        tested_pairs: failures[:tested_pairs],
        invalid_pair_count: failures[:pairs].length,
        invalid_pairs: failures[:pairs]
      },
      hard_gate_would_pass:
        topology[:status] == 'PASS' && failures[:pairs].empty?,
      improvement: {
        invalid_pair_count_before: probe.dig(:hard_gate, :geometry, :invalid_pair_count).to_i,
        invalid_pair_count_after: failures[:pairs].length,
        invalid_pair_reduction:
          probe.dig(:hard_gate, :geometry, :invalid_pair_count).to_i - failures[:pairs].length
      }
    }

    base.merge(
      plane: plane,
      boundary_self_intersections: [],
      triangulation: triangulation.reject { |key, _value| key == :triangles }.merge(
        triangles: new_face_triangles
      ),
      simulation: simulation
    )
  end

  def unsupported(reason)
    { status: 'UNSUPPORTED', reason: reason, hard_gate_would_pass: false }
  end

  def edge_inventory(records)
    inventory = Hash.new { |hash, key| hash[key] = [] }
    records.each_with_index do |record, index|
      points = record.fetch(:points_source_or_grid)
      3.times do |edge_index|
        inventory[canonical_edge(points[edge_index], points[(edge_index + 1) % 3])] << index
      end
    end
    inventory
  end

  def edge_inventory_from_triangles(triangles)
    inventory = Hash.new { |hash, key| hash[key] = [] }
    triangles.each_with_index do |points, index|
      3.times do |edge_index|
        inventory[canonical_edge(points[edge_index], points[(edge_index + 1) % 3])] << index
      end
    end
    inventory
  end

  def boundary_loops(edges)
    adjacency = Hash.new { |hash, key| hash[key] = [] }
    edges.each do |a, b|
      adjacency[a] << b
      adjacency[b] << a
    end
    bad_vertices = adjacency.select { |_vertex, neighbors| neighbors.uniq.length != 2 }
    return {
      valid_degree_two: false,
      bad_vertices: bad_vertices.map { |vertex, neighbors| { vertex: vertex, neighbors: neighbors.uniq } },
      loops: []
    } unless bad_vertices.empty?

    unused = edges.each_with_object({}) { |edge, hash| hash[canonical_edge(*edge)] = true }
    loops = []
    until unused.empty?
      first_edge = unused.keys.first
      start = first_edge[0]
      previous = nil
      current = start
      loop_points = []

      loop do
        loop_points << current
        neighbors = adjacency.fetch(current).uniq
        following = neighbors.find do |neighbor|
          key = canonical_edge(current, neighbor)
          unused[key] && neighbor != previous
        end
        following ||= neighbors.find { |neighbor| unused[canonical_edge(current, neighbor)] }
        break unless following

        unused.delete(canonical_edge(current, following))
        previous, current = current, following
        break if current == start
      end

      loops << loop_points
    end

    {
      valid_degree_two: true,
      bad_vertices: [],
      loop_count: loops.length,
      loops: loops,
      loop_vertex_counts: loops.map(&:length)
    }
  end

  def exact_plane(loop_points, face_records)
    all_points = face_records.flat_map { |record| record[:points_source_or_grid] }.uniq
    origin = loop_points.first
    normal = nil
    loop_points.each_index do |index|
      a = loop_points[index]
      b = loop_points[(index + 1) % loop_points.length]
      c = loop_points[(index + 2) % loop_points.length]
      candidate = integer_cross(integer_subtract(b, a), integer_subtract(c, a))
      unless zero_vector?(candidate)
        normal = candidate
        origin = a
        break
      end
    end
    return { coplanar: false, reason: 'boundary is collinear' } unless normal

    deviations = all_points.filter_map do |point|
      value = integer_dot(normal, integer_subtract(point, origin))
      { point: point, signed_plane_value: value } unless value.zero?
    end
    drop_axis = normal.each_index.max_by { |axis| normal[axis].abs }
    {
      coplanar: deviations.empty?,
      origin: origin,
      normal: normal,
      drop_axis: drop_axis,
      non_coplanar_vertex_count: deviations.length,
      non_coplanar_samples: deviations.first(20)
    }
  end

  def polygon_self_intersections(points, drop_axis)
    projected = points.map { |point| project(point, drop_axis) }
    intersections = []
    n = projected.length
    n.times do |i|
      a = projected[i]
      b = projected[(i + 1) % n]
      ((i + 1)...n).each do |j|
        next if j == i
        next if (i + 1) % n == j
        next if (j + 1) % n == i
        next if i.zero? && j == n - 1

        c = projected[j]
        d = projected[(j + 1) % n]
        if segments_intersect_outside_shared_endpoint?(a, b, c, d)
          intersections << { edge_indices: [i, j], edges: [[points[i], points[(i + 1) % n]], [points[j], points[(j + 1) % n]]] }
        end
      end
    end
    intersections
  end

  def ear_clip(points, drop_axis, reference_normal)
    projected = points.map { |point| project(point, drop_axis) }
    area2 = polygon_area_twice(projected)
    return { ok: false, reason: 'boundary loop has zero projected area' } if area2.zero?

    sign = area2.positive? ? 1 : -1
    remaining = points.each_index.to_a
    triangles = []
    guard = 0

    while remaining.length > 3
      guard += 1
      return { ok: false, reason: 'ear clipping exceeded iteration guard' } if guard > points.length * points.length

      ear_position = remaining.each_index.find do |position|
        prev_i = remaining[(position - 1) % remaining.length]
        curr_i = remaining[position]
        next_i = remaining[(position + 1) % remaining.length]
        a = projected[prev_i]
        b = projected[curr_i]
        c = projected[next_i]
        turn = cross2(a, b, c)
        next false if turn.zero? || turn * sign <= 0

        blocked = remaining.any? do |other_i|
          next false if other_i == prev_i || other_i == curr_i || other_i == next_i
          point_in_triangle_inclusive?(projected[other_i], a, b, c, sign)
        end
        next false if blocked

        diagonal_clear?(projected, remaining, prev_i, next_i)
      end

      unless ear_position
        return {
          ok: false,
          reason: 'no exact non-degenerate ear found while preserving every boundary vertex',
          remaining_vertex_count: remaining.length,
          remaining_points: remaining.map { |index| points[index] }
        }
      end

      prev_i = remaining[(ear_position - 1) % remaining.length]
      curr_i = remaining[ear_position]
      next_i = remaining[(ear_position + 1) % remaining.length]
      triangles << orient_triangle([points[prev_i], points[curr_i], points[next_i]], reference_normal)
      remaining.delete_at(ear_position)
    end

    final = remaining.map { |index| points[index] }
    final_normal = integer_cross(integer_subtract(final[1], final[0]), integer_subtract(final[2], final[0]))
    return { ok: false, reason: 'final ear is degenerate', remaining_points: final } if zero_vector?(final_normal)
    triangles << orient_triangle(final, reference_normal)

    {
      ok: true,
      input_boundary_vertex_count: points.length,
      output_triangle_count: triangles.length,
      projected_area_twice: area2,
      triangles: triangles
    }
  end

  def diagonal_clear?(projected, remaining, index_a, index_b)
    a = projected[index_a]
    b = projected[index_b]
    remaining.each_with_index.all? do |edge_start_index, position|
      edge_end_index = remaining[(position + 1) % remaining.length]
      next true if [edge_start_index, edge_end_index].include?(index_a)
      next true if [edge_start_index, edge_end_index].include?(index_b)

      c = projected[edge_start_index]
      d = projected[edge_end_index]
      !segments_intersect_outside_shared_endpoint?(a, b, c, d)
    end
  end

  def point_in_triangle_inclusive?(point, a, b, c, sign)
    values = [cross2(a, b, point), cross2(b, c, point), cross2(c, a, point)]
    sign.positive? ? values.all? { |value| value >= 0 } : values.all? { |value| value <= 0 }
  end

  def segments_intersect_outside_shared_endpoint?(a, b, c, d)
    shared = [a, b] & [c, d]
    return false unless shared.empty?

    o1 = cross2(a, b, c)
    o2 = cross2(a, b, d)
    o3 = cross2(c, d, a)
    o4 = cross2(c, d, b)

    return true if opposite_signs?(o1, o2) && opposite_signs?(o3, o4)
    return true if o1.zero? && point_between_2d?(c, a, b)
    return true if o2.zero? && point_between_2d?(d, a, b)
    return true if o3.zero? && point_between_2d?(a, c, d)
    return true if o4.zero? && point_between_2d?(b, c, d)

    false
  end

  def opposite_signs?(a, b)
    (a.positive? && b.negative?) || (a.negative? && b.positive?)
  end

  def point_between_2d?(point, a, b)
    point[0] >= [a[0], b[0]].min && point[0] <= [a[0], b[0]].max &&
      point[1] >= [a[1], b[1]].min && point[1] <= [a[1], b[1]].max
  end

  def polygon_area_twice(points)
    points.each_index.sum do |index|
      a = points[index]
      b = points[(index + 1) % points.length]
      (a[0] * b[1]) - (a[1] * b[0])
    end
  end

  def cross2(a, b, c)
    ((b[0] - a[0]) * (c[1] - a[1])) - ((b[1] - a[1]) * (c[0] - a[0]))
  end

  def orient_triangle(triangle, reference_normal)
    normal = integer_cross(
      integer_subtract(triangle[1], triangle[0]),
      integer_subtract(triangle[2], triangle[0])
    )
    integer_dot(normal, reference_normal).negative? ? [triangle[0], triangle[2], triangle[1]] : triangle
  end

  def project(point, drop_axis)
    point.each_with_index.filter_map { |value, axis| value unless axis == drop_axis }
  end

  def canonical_edge(point_a, point_b)
    (point_a <=> point_b) <= 0 ? [point_a, point_b] : [point_b, point_a]
  end

  def integer_subtract(a, b)
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
  end

  def integer_dot(a, b)
    (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2])
  end

  def integer_cross(a, b)
    [
      (a[1] * b[2]) - (a[2] * b[1]),
      (a[2] * b[0]) - (a[0] * b[2]),
      (a[0] * b[1]) - (a[1] * b[0])
    ]
  end

  def zero_vector?(vector)
    vector.all?(&:zero?)
  end

  def json_safe(value)
    case value
    when Rational
      { numerator: value.numerator, denominator: value.denominator }
    when Hash
      value.each_with_object({}) { |(key, item), output| output[key] = json_safe(item) }
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
    puts '[LVN GRID FACE RETRIANGULATION PROBE]'
    puts "target=#{result.dig(:target, :label)} pid=#{result.dig(:target, :pid)} name=#{result.dig(:target, :name).inspect}"
    puts "mode=#{result[:normalization_mode]} operation_aborted=#{result[:operation_aborted]}"
    puts "source_face_key=#{result[:source_face_key]} triangles=#{result[:source_face_triangle_count]} " \
         "vertices=#{result[:source_face_vertex_count]} boundary_edges=#{result[:source_face_boundary_edge_count]} " \
         "loops=#{result.dig(:boundary, :loop_count)}"

    simulation = result[:simulation] || {}
    puts "simulation_status=#{simulation[:status]}"
    if simulation[:status] == 'UNSUPPORTED'
      puts "reason=#{simulation[:reason]}"
    else
      puts "boundary_preserved=#{simulation[:source_face_boundary_preserved]}"
      puts "face_triangles=#{simulation[:source_face_triangle_count_before]} -> #{simulation[:source_face_triangle_count_after]}"
      puts "topology=#{simulation.dig(:topology, :status)} closed_2_manifold=#{simulation.dig(:topology, :closed_2_manifold)} " \
           "components=#{simulation.dig(:topology, :component_count)}"
      puts "invalid_pairs=#{simulation.dig(:improvement, :invalid_pair_count_before)} -> " \
           "#{simulation.dig(:improvement, :invalid_pair_count_after)} " \
           "(reduction=#{simulation.dig(:improvement, :invalid_pair_reduction)})"
      puts "hard_gate_would_pass=#{simulation[:hard_gate_would_pass]}"
    end
    puts '=' * 100
  end
end
