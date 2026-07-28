# frozen_string_literal: true

# Standalone experiment for merging connected coplanar triangle components.
#
# Production LocalVertexNormalizer is intentionally untouched.
# The selected solid is copied and made unique; only the copy is modified.
#
# SketchUp Ruby Console:
#   load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_coplanar_triangle_merge_experiment.rb'
#   LvnCoplanarTriangleMergeExperiment.run

Object.send(:remove_const, :LvnCoplanarTriangleMergeExperiment) if
  defined?(LvnCoplanarTriangleMergeExperiment)

module LvnCoplanarTriangleMergeExperiment
  MM_PER_INCH = 25.4
  DEFAULT_ANGLE_TOLERANCE_DEG = 0.01
  DEFAULT_PLANE_TOLERANCE_MM = 0.001
  DEFAULT_COPY_OFFSET_MM = 3_000.0

  module_function

  def run(
    angle_tolerance_deg: DEFAULT_ANGLE_TOLERANCE_DEG,
    plane_tolerance_mm: DEFAULT_PLANE_TOLERANCE_MM,
    copy_offset_mm: DEFAULT_COPY_OFFSET_MM,
    triangles_only: true
  )
    model = Sketchup.active_model
    source = selected_solid(model)
    unless source
      puts '[COPLANAR TRIANGLE MERGE] Select exactly one manifold Group/ComponentInstance.'
      return nil
    end

    copy = create_test_copy(model, source, copy_offset_mm)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    report = merge_coplanar_triangle_components(
      copy,
      model: model,
      angle_tolerance_deg: angle_tolerance_deg.to_f,
      plane_tolerance_mm: plane_tolerance_mm.to_f,
      triangles_only: triangles_only
    )
    report[:elapsed_sec] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    report[:source_pid] = safe_pid(source)
    report[:source_name] = entity_name(source)
    report[:copy_pid] = safe_pid(copy)
    report[:copy_name] = entity_name(copy)

    $lvn_coplanar_triangle_merge_experiment = report
    print_report(report)
    nil
  rescue StandardError => error
    puts '[COPLANAR TRIANGLE MERGE] FATAL'
    puts "#{error.class}: #{error.message}"
    puts Array(error.backtrace).first(20).join("\n")
    nil
  end

  # Groups adjacent triangles by pairwise coplanarity, then removes every
  # internal edge of each connected component in one erase_entities call.
  #
  # Connectivity is transitive: when A-B, B-C and B-D qualify, A/B/C/D are one
  # candidate component. The whole component is accepted only if SketchUp turns
  # it into exactly one fewer face per merged triangle, keeps a previously closed
  # shell closed, and keeps a previously manifold solid manifold. A rejected
  # component is rolled back independently; earlier accepted components remain.
  def merge_coplanar_triangle_components(
    solid,
    model:,
    angle_tolerance_deg:,
    plane_tolerance_mm:,
    triangles_only: true
  )
    validate_solid!(solid)
    entities = solid.definition.entities
    faces = entities.grep(Sketchup::Face).select(&:valid?)
    faces = faces.select { |face| face.vertices.length == 3 } if triangles_only

    face_by_id = faces.to_h { |face| [stable_entity_id(face), face] }
    adjacency = Hash.new { |hash, key| hash[key] = [] }
    qualifying_pair_metrics = {}

    entities.grep(Sketchup::Edge).each do |edge|
      next unless edge&.valid? && edge.faces.length == 2

      face_a, face_b = edge.faces
      id_a = stable_entity_id(face_a)
      id_b = stable_entity_id(face_b)
      next unless face_by_id.key?(id_a) && face_by_id.key?(id_b)
      next if id_a == id_b

      key = canonical_pair_key(id_a, id_b)
      metrics = qualifying_pair_metrics[key]
      unless metrics
        metrics = coplanar_pair_metrics(
          face_a,
          face_b,
          angle_tolerance_deg: angle_tolerance_deg,
          plane_tolerance_mm: plane_tolerance_mm
        )
        qualifying_pair_metrics[key] = metrics if metrics
      end
      next unless metrics

      adjacency[id_a] << id_b unless adjacency[id_a].include?(id_b)
      adjacency[id_b] << id_a unless adjacency[id_b].include?(id_a)
    end

    components = connected_face_components(face_by_id.keys, adjacency)
                 .select { |component| component.length > 1 }
                 .sort_by { |component| [-component.length, component.min] }

    initial_topology = geometry_counts(entities)
    initial_manifold = manifold?(solid)
    results = []

    components.each_with_index do |component_ids, component_index|
      result = merge_one_component(
        solid,
        model,
        component_ids,
        qualifying_pair_metrics,
        angle_tolerance_deg: angle_tolerance_deg,
        plane_tolerance_mm: plane_tolerance_mm,
        ordinal: component_index + 1,
        total: components.length
      )
      results << result
      print_component_result(result)
    end

    final_topology = geometry_counts(entities)
    {
      angle_tolerance_deg: angle_tolerance_deg,
      plane_tolerance_mm: plane_tolerance_mm,
      triangles_only: triangles_only,
      initial_candidate_face_count: faces.length,
      candidate_component_count: components.length,
      accepted_component_count: results.count { |entry| entry[:accepted] },
      rejected_component_count: results.count { |entry| !entry[:accepted] },
      merged_input_face_count: results.select { |entry| entry[:accepted] }
                                      .sum { |entry| entry[:input_face_count] },
      removed_internal_edge_count: results.select { |entry| entry[:accepted] }
                                          .sum { |entry| entry[:internal_edge_count] },
      initial_topology: initial_topology,
      final_topology: final_topology,
      initial_manifold: initial_manifold,
      final_manifold: manifold?(solid),
      components: results
    }
  end

  def merge_one_component(
    solid,
    model,
    component_ids,
    qualifying_pair_metrics,
    angle_tolerance_deg:,
    plane_tolerance_mm:,
    ordinal:,
    total:
  )
    entities = solid.definition.entities
    current_faces = entities.grep(Sketchup::Face).select do |face|
      face.valid? && component_ids.include?(stable_entity_id(face))
    end

    if current_faces.length != component_ids.length
      return rejected_component_result(
        ordinal,
        total,
        component_ids,
        :component_faces_changed_before_merge,
        input_face_count: current_faces.length
      )
    end

    component_set = component_ids.to_h { |id| [id, true] }
    internal_edges = []
    pair_metrics = []
    disqualifying_pairs = []

    entities.grep(Sketchup::Edge).each do |edge|
      next unless edge&.valid? && edge.faces.length == 2

      face_a, face_b = edge.faces
      id_a = stable_entity_id(face_a)
      id_b = stable_entity_id(face_b)
      next unless component_set[id_a] && component_set[id_b]

      key = canonical_pair_key(id_a, id_b)
      metrics = qualifying_pair_metrics[key] || coplanar_pair_metrics(
        face_a,
        face_b,
        angle_tolerance_deg: angle_tolerance_deg,
        plane_tolerance_mm: plane_tolerance_mm
      )

      unless metrics
        disqualifying_pairs << key
        next
      end

      internal_edges << edge
      pair_metrics << metrics
    end

    unless disqualifying_pairs.empty?
      return rejected_component_result(
        ordinal,
        total,
        component_ids,
        :internal_adjacency_not_coplanar,
        input_face_count: current_faces.length,
        disqualifying_pairs: disqualifying_pairs.uniq
      )
    end

    if internal_edges.empty?
      return rejected_component_result(
        ordinal,
        total,
        component_ids,
        :no_internal_edges,
        input_face_count: current_faces.length
      )
    end

    topology_before = geometry_counts(entities)
    manifold_before = manifold?(solid)
    expected_face_reduction = current_faces.length - 1
    operation_started = false

    begin
      operation_started = model.start_operation('Merge coplanar triangle component', true)
      raise 'Could not start merge operation' unless operation_started

      # The defining experiment: remove the full connected component boundary
      # subdivision atomically, not edge-by-edge.
      entities.erase_entities(internal_edges)

      topology_after = geometry_counts(entities)
      actual_face_reduction = topology_before[:faces] - topology_after[:faces]

      unless actual_face_reduction == expected_face_reduction
        raise "Unexpected face reduction #{actual_face_reduction}; expected #{expected_face_reduction}"
      end
      if topology_before[:closed] && !topology_after[:closed]
        raise 'Merge opened a previously closed shell'
      end
      if topology_after[:overused_edges] > topology_before[:overused_edges]
        raise 'Merge increased overused-edge count'
      end
      if topology_after[:boundary_edges] > topology_before[:boundary_edges]
        raise 'Merge increased boundary-edge count'
      end
      if manifold_before && !manifold?(solid)
        raise 'Merge changed a previously manifold solid into non-manifold geometry'
      end

      model.commit_operation
      operation_started = false

      {
        index: ordinal,
        total: total,
        accepted: true,
        reason: nil,
        face_ids: component_ids,
        input_face_count: current_faces.length,
        internal_edge_count: internal_edges.length,
        expected_face_reduction: expected_face_reduction,
        actual_face_reduction: actual_face_reduction,
        max_angle_deg: pair_metrics.map { |metrics| metrics[:angle_deg] }.max || 0.0,
        max_plane_deviation_mm:
          pair_metrics.map { |metrics| metrics[:plane_deviation_mm] }.max || 0.0,
        topology_before: topology_before,
        topology_after: topology_after,
        manifold_before: manifold_before,
        manifold_after: manifold?(solid)
      }
    rescue StandardError => error
      model.abort_operation if operation_started
      rejected_component_result(
        ordinal,
        total,
        component_ids,
        :merge_rejected,
        input_face_count: current_faces.length,
        internal_edge_count: internal_edges.length,
        max_angle_deg: pair_metrics.map { |metrics| metrics[:angle_deg] }.max || 0.0,
        max_plane_deviation_mm:
          pair_metrics.map { |metrics| metrics[:plane_deviation_mm] }.max || 0.0,
        error: "#{error.class}: #{error.message}"
      )
    end
  end

  def coplanar_pair_metrics(face_a, face_b, angle_tolerance_deg:, plane_tolerance_mm:)
    return nil unless face_a&.valid? && face_b&.valid?

    normal_a = vector_components(face_a.normal)
    normal_b = vector_components(face_b.normal)
    length_product = vector_length(normal_a) * vector_length(normal_b)
    return nil unless length_product.positive?

    cosine = vector_dot(normal_a, normal_b) / length_product
    # Same outward direction only. Opposite faces are never merge candidates.
    return nil unless cosine.positive?

    cosine = [[cosine, -1.0].max, 1.0].min
    angle_deg = Math.acos(cosine) * 180.0 / Math::PI
    return nil if angle_deg > angle_tolerance_deg

    deviation_mm = [
      face_plane_deviation_mm(face_a, face_b),
      face_plane_deviation_mm(face_b, face_a)
    ].max
    return nil if deviation_mm > plane_tolerance_mm

    {
      angle_deg: angle_deg,
      plane_deviation_mm: deviation_mm
    }
  rescue StandardError
    nil
  end

  def face_plane_deviation_mm(source_face, reference_face)
    plane = reference_face.plane.map(&:to_f)
    denominator = Math.sqrt((plane[0]**2) + (plane[1]**2) + (plane[2]**2))
    return Float::INFINITY if denominator.zero?

    source_face.vertices.map do |vertex|
      point = vertex.position
      numerator = (
        (plane[0] * point.x.to_f) +
        (plane[1] * point.y.to_f) +
        (plane[2] * point.z.to_f) +
        plane[3]
      ).abs
      numerator * MM_PER_INCH / denominator
    end.max || 0.0
  end

  def connected_face_components(face_ids, adjacency)
    visited = {}
    face_ids.filter_map do |seed|
      next if visited[seed]

      visited[seed] = true
      queue = [seed]
      component = []
      until queue.empty?
        current = queue.shift
        component << current
        adjacency[current].each do |neighbor|
          next if visited[neighbor]

          visited[neighbor] = true
          queue << neighbor
        end
      end
      component.sort
    end
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

  def create_test_copy(model, source, offset_mm)
    operation_started = false
    begin
      operation_started = model.start_operation('Create coplanar merge test copy', true)
      raise 'Could not start copy operation' unless operation_started

      copy = source.respond_to?(:copy) ? source.copy : nil
      raise "Could not copy #{entity_name(source)}" unless copy&.valid?

      copy.make_unique if copy.respond_to?(:make_unique)
      copy.name = "#{entity_name(source)} [COPLANAR TRIANGLE MERGE TEST]"
      offset_in = offset_mm.to_f / MM_PER_INCH
      copy.transform!(Geom::Transformation.translation([offset_in, 0.0, 0.0]))

      model.commit_operation
      operation_started = false
      copy
    rescue StandardError
      model.abort_operation if operation_started
      raise
    end
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

  def canonical_pair_key(first, second)
    first <= second ? [first, second] : [second, first]
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

  def rejected_component_result(index, total, face_ids, reason, **extra)
    {
      index: index,
      total: total,
      accepted: false,
      reason: reason,
      face_ids: face_ids
    }.merge(extra)
  end

  def print_component_result(result)
    status = result[:accepted] ? 'OK  ' : 'SKIP'
    puts format(
      '[COPLANAR TRIANGLE MERGE] %d/%d %s faces=%d edges=%d angle=%.9fdeg dev=%.9fmm%s',
      result[:index],
      result[:total],
      status,
      result[:input_face_count].to_i,
      result[:internal_edge_count].to_i,
      result[:max_angle_deg].to_f,
      result[:max_plane_deviation_mm].to_f,
      result[:accepted] ? '' : " reason=#{result[:reason]} #{result[:error]}"
    )
  end

  def print_report(report)
    puts '=' * 110
    puts '[COPLANAR TRIANGLE MERGE] COMPLETE'
    puts "source=#{report[:source_name]} PID=#{report[:source_pid]}"
    puts "copy=#{report[:copy_name]} PID=#{report[:copy_pid]}"
    puts "angle_tolerance=#{report[:angle_tolerance_deg]} deg"
    puts "plane_tolerance=#{report[:plane_tolerance_mm]} mm"
    puts "candidate_faces=#{report[:initial_candidate_face_count]}"
    puts "components=#{report[:candidate_component_count]} accepted=#{report[:accepted_component_count]} rejected=#{report[:rejected_component_count]}"
    puts "faces=#{report.dig(:initial_topology, :faces)} -> #{report.dig(:final_topology, :faces)}"
    puts "edges=#{report.dig(:initial_topology, :edges)} -> #{report.dig(:final_topology, :edges)}"
    puts "manifold=#{report[:initial_manifold]} -> #{report[:final_manifold]}"
    puts format('elapsed=%.3f s', report[:elapsed_sec].to_f)
    puts '=' * 110
  end
end

nil
