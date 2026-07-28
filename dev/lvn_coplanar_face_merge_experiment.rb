# frozen_string_literal: true

# Standalone experiment for merging connected near-coplanar Face patches.
#
# Production LocalVertexNormalizer is intentionally untouched.
# No explicit adjacency graph is built. SketchUp topology itself is traversed:
#   Face#edges -> Edge#faces
#
# Algorithm:
#   1. Start from an unvisited Face in the selected manifold solid.
#   2. Implicit BFS through shared edges while adjacent Face normals are within
#      the angular tolerance.
#   3. Fit one representative plane to all unique vertices of that normal
#      component.
#   4. Faces containing a vertex outside the plane tolerance are separated out.
#      Remaining Faces are split again by implicit connectivity and refit
#      recursively until every accepted patch satisfies the plane tolerance.
#   5. Remove every internal shared edge of each accepted patch atomically.
#
# Triangle, quad and general n-gon Faces are all candidates. Face arity is not
# used as a filter.
#
# The selected solid itself is modified in one SketchUp operation. The whole
# operation is aborted if any merge damages closed/manifold topology. Use Undo
# to revert a successful test.
#
# SketchUp Ruby Console:
#   load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_coplanar_face_merge_experiment.rb'
#   LvnCoplanarFaceMergeExperiment.run

Object.send(:remove_const, :LvnCoplanarFaceMergeExperiment) if
  defined?(LvnCoplanarFaceMergeExperiment)

module LvnCoplanarFaceMergeExperiment
  MM_PER_INCH = 25.4
  DEFAULT_ANGLE_TOLERANCE_DEG = 0.01
  DEFAULT_PLANE_TOLERANCE_MM = 0.001

  module_function

  def run(
    angle_tolerance_deg: DEFAULT_ANGLE_TOLERANCE_DEG,
    plane_tolerance_mm: DEFAULT_PLANE_TOLERANCE_MM
  )
    model = Sketchup.active_model
    solid = selected_solid(model)
    unless solid
      puts '[COPLANAR FACE MERGE] Select exactly one manifold Group/ComponentInstance.'
      return nil
    end

    angle_tolerance_deg = Float(angle_tolerance_deg)
    plane_tolerance_mm = Float(plane_tolerance_mm)
    raise ArgumentError, 'angle_tolerance_deg must be >= 0' if angle_tolerance_deg.negative?
    raise ArgumentError, 'plane_tolerance_mm must be >= 0' if plane_tolerance_mm.negative?

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    operation_started = false

    begin
      operation_started = model.start_operation('Merge near-coplanar face patches', true)
      raise 'Could not start coplanar face merge operation' unless operation_started

      # Prevent one selected ComponentInstance from modifying sibling instances.
      solid.make_unique if solid.respond_to?(:make_unique)

      report = merge_near_coplanar_patches(
        solid,
        angle_tolerance_deg: angle_tolerance_deg,
        plane_tolerance_mm: plane_tolerance_mm
      )

      unless manifold?(solid)
        raise 'Final selected solid is not manifold after coplanar face merge'
      end

      model.commit_operation
      operation_started = false

      report[:elapsed_sec] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      report[:solid_pid] = safe_pid(solid)
      report[:solid_name] = entity_name(solid)
      report[:success] = true

      $lvn_coplanar_face_merge_experiment = report
      print_report(report)
      nil
    rescue StandardError => error
      model.abort_operation if operation_started

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      report = {
        success: false,
        solid_pid: safe_pid(solid),
        solid_name: entity_name(solid),
        angle_tolerance_deg: angle_tolerance_deg,
        plane_tolerance_mm: plane_tolerance_mm,
        elapsed_sec: elapsed,
        error: "#{error.class}: #{error.message}"
      }
      $lvn_coplanar_face_merge_experiment = report

      puts '[COPLANAR FACE MERGE] FAILED / operation rolled back'
      puts report[:error]
      puts Array(error.backtrace).first(20).join("\n")
      nil
    end
  end

  def merge_near_coplanar_patches(solid, angle_tolerance_deg:, plane_tolerance_mm:)
    validate_solid!(solid)
    entities = solid.definition.entities
    all_faces = entities.grep(Sketchup::Face).select(&:valid?)

    face_by_id = all_faces.to_h do |face|
      [stable_entity_id(face), face]
    end

    # Mark table only; no adjacency graph is materialized.
    unvisited = face_by_id.keys.to_h { |face_id| [face_id, true] }
    normal_components = []

    until unvisited.empty?
      seed_id = unvisited.keys.first
      seed = face_by_id[seed_id]
      unless seed&.valid?
        unvisited.delete(seed_id)
        next
      end

      component = collect_normal_component(
        seed,
        allowed_ids: unvisited,
        angle_tolerance_deg: angle_tolerance_deg
      )

      component.each { |face| unvisited.delete(stable_entity_id(face)) }
      normal_components << component unless component.empty?
    end

    planar_groups = normal_components.flat_map do |component|
      refine_component_by_best_fit(
        component,
        angle_tolerance_deg: angle_tolerance_deg,
        plane_tolerance_mm: plane_tolerance_mm
      )
    end

    merge_groups = planar_groups
                   .select { |group| group.length > 1 }
                   .sort_by do |group|
                     [-group.length, group.map { |face| stable_entity_id(face) }.min]
                   end

    initial_topology = geometry_counts(entities)
    initial_manifold = manifold?(solid)
    descriptors = merge_groups.map { |group| describe_planar_group(group) }

    puts '=' * 110
    puts '[COPLANAR FACE MERGE] PLAN'
    puts "faces=#{all_faces.length}"
    puts "normal_components=#{normal_components.length} planar_groups=#{planar_groups.length} merge_groups=#{merge_groups.length}"
    puts "angle_tolerance=#{angle_tolerance_deg} deg plane_tolerance=#{plane_tolerance_mm} mm"
    descriptors.each_with_index do |descriptor, index|
      puts format(
        '  %d/%d faces=%d vertices=%d max_angle=%.9fdeg max_dev=%.9fmm',
        index + 1,
        descriptors.length,
        descriptor[:face_count],
        descriptor[:vertex_count],
        descriptor[:max_adjacent_angle_deg],
        descriptor[:max_vertex_deviation_mm]
      )
    end
    puts '=' * 110

    merge_results = []
    merge_groups.each_with_index do |group, index|
      result = merge_one_group!(
        solid,
        group,
        ordinal: index + 1,
        total: merge_groups.length
      )
      merge_results << result
      print_merge_result(result)
    end

    final_topology = geometry_counts(entities)
    final_manifold = manifold?(solid)

    if initial_topology[:closed] && !final_topology[:closed]
      raise 'Coplanar face merge opened a previously closed shell'
    end
    if final_topology[:overused_edges] > initial_topology[:overused_edges]
      raise 'Coplanar face merge increased overused-edge count'
    end
    if final_topology[:boundary_edges] > initial_topology[:boundary_edges]
      raise 'Coplanar face merge increased boundary-edge count'
    end
    if initial_manifold && !final_manifold
      raise 'Coplanar face merge changed a manifold solid into non-manifold geometry'
    end

    {
      angle_tolerance_deg: angle_tolerance_deg,
      plane_tolerance_mm: plane_tolerance_mm,
      source_face_count: all_faces.length,
      normal_component_count: normal_components.length,
      planar_group_count: planar_groups.length,
      singleton_group_count: planar_groups.count { |group| group.length == 1 },
      merge_group_count: merge_groups.length,
      merged_input_face_count: merge_results.sum { |entry| entry[:input_face_count] },
      removed_internal_edge_count: merge_results.sum { |entry| entry[:internal_edge_count] },
      initial_topology: initial_topology,
      final_topology: final_topology,
      initial_manifold: initial_manifold,
      final_manifold: final_manifold,
      groups: descriptors,
      merges: merge_results
    }
  end

  # Implicit BFS. SketchUp Face/Edge incidence is the graph.
  def collect_normal_component(seed, allowed_ids:, angle_tolerance_deg:)
    seed_id = stable_entity_id(seed)
    return [] unless allowed_ids[seed_id]

    queued = { seed_id => true }
    queue = [seed]
    component = []
    cursor = 0

    while cursor < queue.length
      face = queue[cursor]
      cursor += 1
      next unless face&.valid?

      component << face

      face.edges.each do |edge|
        next unless edge&.valid? && edge.faces.length == 2

        neighbor = edge.faces.find { |candidate| candidate != face }
        next unless neighbor&.valid?

        neighbor_id = stable_entity_id(neighbor)
        next unless allowed_ids[neighbor_id]
        next if queued[neighbor_id]
        next unless normal_angle_within?(face, neighbor, angle_tolerance_deg)

        queued[neighbor_id] = true
        queue << neighbor
      end
    end

    component
  end

  # Partition one normal-connected component into connected patches whose every
  # vertex lies within plane_tolerance_mm of that patch's best-fit plane.
  # Faces rejected by one fit are reconsidered recursively rather than discarded.
  def refine_component_by_best_fit(
    faces,
    angle_tolerance_deg:,
    plane_tolerance_mm:,
    depth: 0
  )
    faces = faces.select(&:valid?).uniq
    return [] if faces.empty?
    return [faces] if faces.length == 1

    metrics = best_fit_component_metrics(faces)
    return faces.map { |face| [face] } unless metrics

    bad = faces.select do |face|
      metrics[:face_max_deviation_mm].fetch(
        stable_entity_id(face),
        Float::INFINITY
      ) > plane_tolerance_mm
    end

    return [faces] if bad.empty?

    keep = faces - bad

    # A broad component can put every Face outside the initial fitted plane.
    # Peel only the worst Face in that case so recursion always makes progress.
    if keep.empty?
      worst = faces.max_by do |face|
        metrics[:face_max_deviation_mm].fetch(
          stable_entity_id(face),
          Float::INFINITY
        )
      end
      bad = [worst]
      keep = faces - bad
    end

    result = []

    implicit_subcomponents(
      keep,
      angle_tolerance_deg: angle_tolerance_deg
    ).each do |subcomponent|
      result.concat(
        refine_component_by_best_fit(
          subcomponent,
          angle_tolerance_deg: angle_tolerance_deg,
          plane_tolerance_mm: plane_tolerance_mm,
          depth: depth + 1
        )
      )
    end

    implicit_subcomponents(
      bad,
      angle_tolerance_deg: angle_tolerance_deg
    ).each do |subcomponent|
      result.concat(
        refine_component_by_best_fit(
          subcomponent,
          angle_tolerance_deg: angle_tolerance_deg,
          plane_tolerance_mm: plane_tolerance_mm,
          depth: depth + 1
        )
      )
    end

    result
  end

  def implicit_subcomponents(faces, angle_tolerance_deg:)
    allowed = faces.select(&:valid?).to_h do |face|
      [stable_entity_id(face), true]
    end
    remaining = allowed.dup
    face_by_id = faces.to_h { |face| [stable_entity_id(face), face] }
    components = []

    until remaining.empty?
      seed_id = remaining.keys.first
      seed = face_by_id[seed_id]
      unless seed&.valid?
        remaining.delete(seed_id)
        next
      end

      component = collect_normal_component(
        seed,
        allowed_ids: remaining,
        angle_tolerance_deg: angle_tolerance_deg
      )
      component.each { |face| remaining.delete(stable_entity_id(face)) }
      components << component unless component.empty?
    end

    components
  end

  def best_fit_component_metrics(faces)
    vertices = faces.flat_map(&:vertices).select(&:valid?).uniq
    return nil if vertices.length < 3

    plane = Geom.fit_plane_to_points(vertices.map(&:position))
    return nil unless plane && plane.length == 4

    a, b, c, d = plane.map(&:to_f)
    norm = Math.sqrt((a * a) + (b * b) + (c * c))
    return nil if norm <= 1.0e-15

    face_max = {}
    max_deviation = 0.0

    faces.each do |face|
      deviation = face.vertices.map do |vertex|
        point_plane_distance_mm(vertex.position, [a, b, c, d], norm)
      end.max || 0.0
      face_max[stable_entity_id(face)] = deviation
      max_deviation = [max_deviation, deviation].max
    end

    {
      plane: [a, b, c, d],
      plane_norm: norm,
      vertex_count: vertices.length,
      max_vertex_deviation_mm: max_deviation,
      face_max_deviation_mm: face_max
    }
  rescue StandardError
    nil
  end

  def point_plane_distance_mm(point, plane, norm = nil)
    a, b, c, d = plane
    denominator = norm || Math.sqrt((a * a) + (b * b) + (c * c))
    return Float::INFINITY if denominator <= 1.0e-15

    numerator = (
      (a * point.x.to_f) +
      (b * point.y.to_f) +
      (c * point.z.to_f) +
      d
    ).abs
    numerator * MM_PER_INCH / denominator
  end

  def normal_angle_within?(face_a, face_b, tolerance_deg)
    angle = normal_angle_deg(face_a, face_b)
    !angle.nil? && angle <= tolerance_deg
  end

  def normal_angle_deg(face_a, face_b)
    return nil unless face_a&.valid? && face_b&.valid?

    first = vector_components(face_a.normal)
    second = vector_components(face_b.normal)
    denominator = vector_length(first) * vector_length(second)
    return nil unless denominator.positive?

    cosine = vector_dot(first, second) / denominator
    # Opposite-facing surface Faces must never be merged.
    return nil unless cosine.positive?

    cosine = [[cosine, -1.0].max, 1.0].min
    Math.acos(cosine) * 180.0 / Math::PI
  rescue StandardError
    nil
  end

  def describe_planar_group(faces)
    metrics = best_fit_component_metrics(faces)
    {
      face_ids: faces.map { |face| stable_entity_id(face) }.sort,
      face_count: faces.length,
      vertex_count: metrics ? metrics[:vertex_count] : 0,
      max_vertex_deviation_mm:
        metrics ? metrics[:max_vertex_deviation_mm] : Float::INFINITY,
      max_adjacent_angle_deg: max_adjacent_angle_deg(faces)
    }
  end

  def max_adjacent_angle_deg(faces)
    allowed = faces.to_h { |face| [stable_entity_id(face), true] }
    seen_edges = {}
    angles = []

    faces.each do |face|
      face.edges.each do |edge|
        next unless edge&.valid? && edge.faces.length == 2

        edge_id = stable_entity_id(edge)
        next if seen_edges[edge_id]

        face_a, face_b = edge.faces
        next unless allowed[stable_entity_id(face_a)] &&
                    allowed[stable_entity_id(face_b)]

        seen_edges[edge_id] = true
        angle = normal_angle_deg(face_a, face_b)
        angles << angle if angle
      end
    end

    angles.max || 0.0
  end

  def merge_one_group!(solid, faces, ordinal:, total:)
    entities = solid.definition.entities
    current_faces = faces.select(&:valid?)
    unless current_faces.length == faces.length
      raise "Merge group #{ordinal}/#{total} changed before merge"
    end

    face_ids = current_faces.to_h do |face|
      [stable_entity_id(face), true]
    end

    internal_edges = current_faces.flat_map(&:edges).uniq.select do |edge|
      next false unless edge&.valid? && edge.faces.length == 2

      face_a, face_b = edge.faces
      face_ids[stable_entity_id(face_a)] && face_ids[stable_entity_id(face_b)]
    end

    if internal_edges.empty?
      raise "Merge group #{ordinal}/#{total} has no internal shared edges"
    end

    descriptor = describe_planar_group(current_faces)
    topology_before = geometry_counts(entities)
    manifold_before = manifold?(solid)
    expected_face_reduction = current_faces.length - 1

    entities.erase_entities(internal_edges)

    topology_after = geometry_counts(entities)
    actual_face_reduction = topology_before[:faces] - topology_after[:faces]

    unless actual_face_reduction == expected_face_reduction
      raise "Merge group #{ordinal}/#{total} reduced faces by #{actual_face_reduction}; expected #{expected_face_reduction}"
    end
    if topology_before[:closed] && !topology_after[:closed]
      raise "Merge group #{ordinal}/#{total} opened a previously closed shell"
    end
    if topology_after[:overused_edges] > topology_before[:overused_edges]
      raise "Merge group #{ordinal}/#{total} increased overused-edge count"
    end
    if topology_after[:boundary_edges] > topology_before[:boundary_edges]
      raise "Merge group #{ordinal}/#{total} increased boundary-edge count"
    end
    if manifold_before && !manifold?(solid)
      raise "Merge group #{ordinal}/#{total} changed a manifold solid into non-manifold geometry"
    end

    {
      index: ordinal,
      total: total,
      input_face_count: current_faces.length,
      input_vertex_count: current_faces.flat_map(&:vertices).uniq.length,
      internal_edge_count: internal_edges.length,
      expected_face_reduction: expected_face_reduction,
      actual_face_reduction: actual_face_reduction,
      max_adjacent_angle_deg: descriptor[:max_adjacent_angle_deg],
      max_vertex_deviation_mm: descriptor[:max_vertex_deviation_mm],
      topology_before: topology_before,
      topology_after: topology_after,
      manifold_before: manifold_before,
      manifold_after: manifold?(solid)
    }
  end

  def geometry_counts(entities)
    faces = entities.grep(Sketchup::Face).select(&:valid?)
    edges = entities.grep(Sketchup::Edge).select(&:valid?)
    boundary_edges = edges.count { |edge| edge.faces.length == 1 }
    overused_edges = edges.count { |edge| edge.faces.length > 2 }
    {
      faces: faces.length,
      edges: edges.length,
      boundary_edges: boundary_edges,
      overused_edges: overused_edges,
      stray_edges: edges.count { |edge| edge.faces.empty? },
      closed: faces.any? && boundary_edges.zero? && overused_edges.zero?
    }
  end

  def selected_solid(model)
    candidates = model.selection.to_a.select do |entity|
      entity&.valid? && entity.respond_to?(:definition) && entity.respond_to?(:manifold?)
    end
    return nil unless candidates.length == 1

    candidate = candidates.first
    candidate.manifold? == true ? candidate : nil
  rescue StandardError
    nil
  end

  def validate_solid!(solid)
    unless solid&.valid? && solid.respond_to?(:definition)
      raise ArgumentError, 'A valid Group/ComponentInstance is required'
    end
  end

  def manifold?(solid)
    solid.respond_to?(:manifold?) && solid.manifold? == true
  rescue StandardError
    false
  end

  def stable_entity_id(entity)
    return entity.persistent_id if entity.respond_to?(:persistent_id)

    entity.object_id
  rescue StandardError
    entity.object_id
  end

  def safe_pid(entity)
    entity.persistent_id
  rescue StandardError
    nil
  end

  def entity_name(entity)
    name = entity.respond_to?(:name) ? entity.name.to_s : ''
    return name unless name.empty?

    if entity.respond_to?(:definition)
      definition_name = entity.definition.name.to_s
      return definition_name unless definition_name.empty?
    end
    entity.class.to_s
  rescue StandardError
    entity.class.to_s
  end

  def vector_components(vector)
    [vector.x.to_f, vector.y.to_f, vector.z.to_f]
  end

  def vector_dot(first, second)
    (first[0] * second[0]) + (first[1] * second[1]) + (first[2] * second[2])
  end

  def vector_length(vector)
    Math.sqrt(vector_dot(vector, vector))
  end

  def print_merge_result(result)
    puts format(
      '[COPLANAR FACE MERGE] %d/%d OK faces=%d vertices=%d edges=%d angle=%.9fdeg best_fit_dev=%.9fmm',
      result[:index],
      result[:total],
      result[:input_face_count],
      result[:input_vertex_count],
      result[:internal_edge_count],
      result[:max_adjacent_angle_deg],
      result[:max_vertex_deviation_mm]
    )
  end

  def print_report(report)
    puts '=' * 110
    puts '[COPLANAR FACE MERGE] COMPLETE'
    puts "solid=#{report[:solid_name]} PID=#{report[:solid_pid]}"
    puts "angle_tolerance=#{report[:angle_tolerance_deg]} deg"
    puts "best_fit_plane_tolerance=#{report[:plane_tolerance_mm]} mm"
    puts "source_faces=#{report[:source_face_count]}"
    puts "normal_components=#{report[:normal_component_count]} planar_groups=#{report[:planar_group_count]} singletons=#{report[:singleton_group_count]}"
    puts "merge_groups=#{report[:merge_group_count]} merged_input_faces=#{report[:merged_input_face_count]}"
    puts "faces=#{report.dig(:initial_topology, :faces)} -> #{report.dig(:final_topology, :faces)}"
    puts "edges=#{report.dig(:initial_topology, :edges)} -> #{report.dig(:final_topology, :edges)}"
    puts "manifold=#{report[:initial_manifold]} -> #{report[:final_manifold]}"
    puts format('elapsed=%.3f s', report[:elapsed_sec].to_f)
    puts '=' * 110
  end
end

nil
