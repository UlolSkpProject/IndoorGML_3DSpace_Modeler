# frozen_string_literal: true

# Simulates retriangulation of only the exact-coplanar, edge-connected portion
# of the snapped source face implicated by the T180/T689 conflict.
#
# SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_grid_coplanar_patch_retriangulation_probe.rb'
# LvnGridCoplanarPatchRetriangulationProbe.run(mode: :normal)
#
# No SketchUp geometry is committed. The underlying deep probe always aborts
# its SketchUp operation; this file only mutates in-memory triangle arrays.

require 'json'
require 'tmpdir'
require 'time'
require_relative 'lvn_near_edge_sliver_probe'

module LvnGridCoplanarPatchRetriangulationProbe
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
      "lvn_grid_coplanar_patch_retriangulation_probe_#{TARGET_LABEL}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
    )
    File.open(path, 'w:UTF-8') { |file| file.write(JSON.pretty_generate(json_safe(result))) }
    result[:json_path] = path
    $lvn_grid_coplanar_patch_retriangulation_probe = result

    print_summary(result)
    puts "\n[LVN GRID COPLANAR PATCH RETRIANGULATION] JSON: #{path}"
    puts '[LVN GRID COPLANAR PATCH RETRIANGULATION] Full result: $lvn_grid_coplanar_patch_retriangulation_probe'
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

    seed_index = candidate.fetch(:owner_triangle)
    seed_record = records.fetch(seed_index)
    source_face_key = seed_record[:source_face_key]
    raise 'Focus host triangle has no source_face_key' unless source_face_key

    seed_triangle = seed_record.fetch(:points_source_or_grid)
    seed_normal = integer_cross(
      integer_subtract(seed_triangle[1], seed_triangle[0]),
      integer_subtract(seed_triangle[2], seed_triangle[0])
    )
    raise 'Focus host triangle is degenerate' if zero_vector?(seed_normal)
    seed_origin = seed_triangle[0]
    drop_axis = seed_normal.each_index.max_by { |axis| seed_normal[axis].abs }

    same_face_indices = records.each_index.select do |index|
      records[index][:source_face_key] == source_face_key
    end
    exact_plane_indices = same_face_indices.select do |index|
      triangle_on_plane?(records[index].fetch(:points_source_or_grid), seed_origin, seed_normal)
    end

    face_edge_owners = edge_owners_for_indices(records, same_face_indices)
    exact_edge_owners = edge_owners_for_indices(records, exact_plane_indices)
    component_indices = connected_component(seed_index, exact_plane_indices, exact_edge_owners, records)
    raise 'Exact-coplanar component did not retain the seed triangle' unless component_indices.include?(seed_index)

    patch_triangles = component_indices.map do |index|
      records[index].fetch(:points_source_or_grid)
    end
    patch_inventory = edge_inventory_from_triangles(patch_triangles)
    boundary_edges = patch_inventory.select { |_edge, owners| owners.length == 1 }.keys
    internal_edges = patch_inventory.select { |_edge, owners| owners.length == 2 }.keys
    overused_edges = patch_inventory.select { |_edge, owners| owners.length > 2 }
    loops = exact_boundary_loops(boundary_edges)

    separating_boundary_edges = boundary_edges.select do |edge|
      owners = Array(face_edge_owners[edge])
      owners.any? { |index| !component_indices.include?(index) }
    end
    external_surface_boundary_edges = boundary_edges.select do |edge|
      Array(face_edge_owners[edge]).length == 1
    end

    base = {
      schema: 'ulol.lvn_grid_coplanar_patch_retriangulation_probe.v1',
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
      seed_triangle_index: seed_index,
      seed_plane: {
        origin: seed_origin,
        normal: seed_normal,
        drop_axis: drop_axis
      },
      source_face_key: source_face_key,
      source_face_triangle_count: same_face_indices.length,
      exact_plane_triangle_count: exact_plane_indices.length,
      component_triangle_count: component_indices.length,
      component_triangle_indices: component_indices,
      component_vertex_count: patch_triangles.flatten(1).uniq.length,
      component_edge_count: patch_inventory.length,
      component_boundary_edge_count: boundary_edges.length,
      component_internal_edge_count: internal_edges.length,
      component_overused_edge_count: overused_edges.length,
      component_boundary_loop_count: loops.length,
      component_boundary_loop_vertex_counts: loops.map(&:length),
      separating_boundary_edge_count: separating_boundary_edges.length,
      external_surface_boundary_edge_count: external_surface_boundary_edges.length,
      separating_boundary_edge_samples: separating_boundary_edges.first(20),
      external_surface_boundary_edge_samples: external_surface_boundary_edges.first(20)
    }

    unless overused_edges.empty?
      return base.merge(simulation: unsupported('exact-coplanar patch local edge incidence exceeds 2'))
    end

    normalizer = Deep::ProbeNormalizer.new(LVN::DEFAULT_TOLERANCE_MM)
    begin
      outer, holes = normalizer.send(:classify_exact_patch_loops, loops, drop_axis)
      replacement = normalizer.send(
        :triangulate_exact_polygon_with_holes,
        outer,
        holes,
        drop_axis
      )
    rescue StandardError => error
      return base.merge(
        loop_classification: {
          status: 'FAIL',
          error: "#{error.class}: #{error.message}"
        },
        simulation: unsupported('production exact hole-aware patch triangulation rejected this component')
      )
    end

    replacement = replacement.map { |triangle| orient_triangle(triangle, seed_normal) }
    replacement_inventory = edge_inventory_from_triangles(replacement)
    replacement_boundary = replacement_inventory.select { |_edge, owners| owners.length == 1 }.keys
    boundary_preserved = replacement_boundary.sort == boundary_edges.sort

    expected_area2 = polygon_area2(outer, drop_axis).abs - holes.sum do |hole|
      polygon_area2(hole, drop_axis).abs
    end
    replacement_area2 = replacement.sum do |triangle|
      triangle_area2(triangle, drop_axis).abs
    end

    simulated_triangles = records.each_index.filter_map do |index|
      records[index].fetch(:points_source_or_grid) unless component_indices.include?(index)
    end
    simulated_triangles.concat(replacement)

    topology = normalizer.send(:topology_summary, simulated_triangles)
    failures = normalizer.send(:collect_triangle_intersection_failures, simulated_triangles)

    before_pairs = Array(probe.dig(:hard_gate, :geometry, :invalid_pairs))
    simulation = {
      status: 'SIMULATED',
      patch_triangle_count_before: component_indices.length,
      patch_triangle_count_after: replacement.length,
      patch_boundary_preserved: boundary_preserved,
      patch_boundary_edge_count_before: boundary_edges.length,
      patch_boundary_edge_count_after: replacement_boundary.length,
      expected_projected_area2: expected_area2,
      replacement_projected_area2: replacement_area2,
      projected_area_preserved: expected_area2 == replacement_area2,
      total_triangle_count_after: simulated_triangles.length,
      topology: topology,
      geometry: {
        tested_pairs: failures[:tested_pairs],
        invalid_pair_count: failures[:pairs].length,
        invalid_pairs: failures[:pairs]
      },
      hard_gate_would_pass:
        boundary_preserved &&
        expected_area2 == replacement_area2 &&
        topology[:status] == 'PASS' &&
        failures[:pairs].empty?,
      improvement: {
        invalid_pair_count_before: before_pairs.length,
        invalid_pair_count_after: failures[:pairs].length,
        invalid_pair_reduction: before_pairs.length - failures[:pairs].length
      }
    }

    base.merge(
      loop_classification: {
        status: 'PASS',
        outer_vertex_count: outer.length,
        hole_count: holes.length,
        hole_vertex_counts: holes.map(&:length)
      },
      replacement_triangles: replacement,
      simulation: simulation
    )
  end

  def unsupported(reason)
    { status: 'UNSUPPORTED', reason: reason, hard_gate_would_pass: false }
  end

  def triangle_on_plane?(triangle, origin, normal)
    triangle.all? do |point|
      integer_dot(normal, integer_subtract(point, origin)).zero?
    end
  end

  def edge_owners_for_indices(records, indices)
    owners = Hash.new { |hash, key| hash[key] = [] }
    indices.each do |index|
      points = records[index].fetch(:points_source_or_grid)
      3.times do |edge_index|
        owners[canonical_edge(points[edge_index], points[(edge_index + 1) % 3])] << index
      end
    end
    owners
  end

  def connected_component(seed_index, allowed_indices, edge_owners, records)
    allowed = allowed_indices.to_h { |index| [index, true] }
    return [] unless allowed[seed_index]

    visited = {}
    queue = [seed_index]
    until queue.empty?
      index = queue.shift
      next if visited[index]

      visited[index] = true
      points = records[index].fetch(:points_source_or_grid)
      3.times do |edge_index|
        edge = canonical_edge(points[edge_index], points[(edge_index + 1) % 3])
        Array(edge_owners[edge]).each do |neighbor|
          queue << neighbor if allowed[neighbor] && !visited[neighbor]
        end
      end
    end
    visited.keys.sort
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

  def exact_boundary_loops(boundary_edges)
    adjacency = Hash.new { |hash, key| hash[key] = [] }
    boundary_edges.each do |a, b|
      adjacency[a] << b
      adjacency[b] << a
    end
    bad = adjacency.select { |_point, neighbors| neighbors.uniq.length != 2 }
    unless bad.empty?
      raise "Exact-coplanar component boundary is not degree-2: #{bad.first(10).inspect}"
    end

    unused = boundary_edges.each_with_object({}) do |edge, result|
      result[canonical_edge(edge[0], edge[1])] = true
    end
    loops = []
    until unused.empty?
      seed = unused.keys.first
      start_point, current = seed
      previous = start_point
      loop_points = [start_point]
      unused.delete(seed)

      boundary_edges.length.times do
        loop_points << current
        break if current == start_point

        following = adjacency.fetch(current).find do |candidate|
          candidate != previous && unused.key?(canonical_edge(current, candidate))
        end
        following ||= adjacency.fetch(current).find do |candidate|
          unused.key?(canonical_edge(current, candidate))
        end
        raise "Exact-coplanar component boundary did not close at #{current.inspect}" unless following

        unused.delete(canonical_edge(current, following))
        previous, current = current, following
      end

      raise 'Exact-coplanar component boundary walk did not close' unless loop_points.last == start_point

      loop_points.pop
      raise 'Exact-coplanar component boundary loop has fewer than 3 vertices' if loop_points.length < 3

      loops << loop_points
    end
    loops
  end

  def polygon_area2(loop, drop_axis)
    projected = loop.map { |point| project(point, drop_axis) }
    projected.each_index.sum do |index|
      a = projected[index]
      b = projected[(index + 1) % projected.length]
      (a[0] * b[1]) - (a[1] * b[0])
    end
  end

  def triangle_area2(triangle, drop_axis)
    a, b, c = triangle.map { |point| project(point, drop_axis) }
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
    puts '[LVN GRID COPLANAR PATCH RETRIANGULATION PROBE]'
    puts "target=#{result.dig(:target, :label)} pid=#{result.dig(:target, :pid)} name=#{result.dig(:target, :name).inspect}"
    puts "mode=#{result[:normalization_mode]} operation_aborted=#{result[:operation_aborted]}"
    puts "source_face_key=#{result[:source_face_key]} source_face_triangles=#{result[:source_face_triangle_count]}"
    puts "exact_plane_triangles=#{result[:exact_plane_triangle_count]} component_triangles=#{result[:component_triangle_count]} " \
         "loops=#{result[:component_boundary_loop_count]}"
    puts "component_boundary_edges=#{result[:component_boundary_edge_count]} " \
         "separating=#{result[:separating_boundary_edge_count]} external=#{result[:external_surface_boundary_edge_count]}"

    classification = result[:loop_classification] || {}
    puts "loop_classification=#{classification[:status]} outer_vertices=#{classification[:outer_vertex_count]} " \
         "holes=#{classification[:hole_count]}"
    puts "loop_error=#{classification[:error]}" if classification[:error]

    simulation = result[:simulation] || {}
    puts "simulation_status=#{simulation[:status]}"
    if simulation[:status] == 'UNSUPPORTED'
      puts "reason=#{simulation[:reason]}"
    else
      puts "boundary_preserved=#{simulation[:patch_boundary_preserved]} area_preserved=#{simulation[:projected_area_preserved]}"
      puts "patch_triangles=#{simulation[:patch_triangle_count_before]} -> #{simulation[:patch_triangle_count_after]}"
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
