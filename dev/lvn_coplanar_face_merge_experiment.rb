# frozen_string_literal: true

# Standalone runner for the exact same connected near-coplanar Face merge used
# by LocalVertexNormalizer's final stage.
#
# SketchUp Ruby Console:
#   load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_coplanar_face_merge_experiment.rb'
#   LvnCoplanarFaceMergeExperiment.run
#
# Selected-Face diagnostic only (no geometry change):
#   LvnCoplanarFaceMergeExperiment.diagnose_selected_faces

require_relative '../indoor3d/application/local_vertex_normalizer/coplanar_face_component_merge'

Object.send(:remove_const, :LvnCoplanarFaceMergeExperiment) if
  defined?(LvnCoplanarFaceMergeExperiment)

module LvnCoplanarFaceMergeExperiment
  CORE = ULOL::Indoor3DGmlModeler::IndoorCore::CoplanarFaceComponentMerge
  DEFAULT_ANGLE_TOLERANCE_DEG = CORE::DEFAULT_ANGLE_TOLERANCE_DEG
  DEFAULT_PLANE_TOLERANCE_MM = CORE::DEFAULT_PLANE_TOLERANCE_MM

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

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    operation_started = false

    begin
      operation_started = model.start_operation('Merge near-coplanar face patches', true)
      raise 'Could not start coplanar face merge operation' unless operation_started

      # Match the previous standalone behavior: do not mutate sibling instances.
      solid.make_unique if solid.respond_to?(:make_unique)

      report = CORE.merge!(
        solid,
        angle_tolerance_deg: angle_tolerance_deg,
        plane_tolerance_mm: plane_tolerance_mm
      )

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

      report = {
        success: false,
        solid_pid: safe_pid(solid),
        solid_name: entity_name(solid),
        angle_tolerance_deg: angle_tolerance_deg,
        plane_tolerance_mm: plane_tolerance_mm,
        elapsed_sec: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at,
        error: "#{error.class}: #{error.message}"
      }
      $lvn_coplanar_face_merge_experiment = report

      puts '[COPLANAR FACE MERGE] FAILED / operation rolled back'
      puts report[:error]
      puts Array(error.backtrace).first(20).join("\n")
      nil
    end
  end

  def diagnose_selected_faces(
    angle_tolerance_deg: DEFAULT_ANGLE_TOLERANCE_DEG,
    plane_tolerance_mm: DEFAULT_PLANE_TOLERANCE_MM
  )
    model = Sketchup.active_model
    faces = model.selection.grep(Sketchup::Face).select(&:valid?).uniq
    if faces.empty?
      puts '[COPLANAR FACE DIAG] Select one or more Faces.'
      return nil
    end

    angle_tolerance_deg = Float(angle_tolerance_deg)
    plane_tolerance_mm = Float(plane_tolerance_mm)
    components = CORE.implicit_subcomponents(
      faces,
      angle_tolerance_deg: angle_tolerance_deg
    )
    refined = components.flat_map do |component|
      CORE.refine_component_by_best_fit(
        component,
        angle_tolerance_deg: angle_tolerance_deg,
        plane_tolerance_mm: plane_tolerance_mm
      )
    end
    metrics = CORE.best_fit_component_metrics(faces)
    selected_ids = faces.to_h { |face| [CORE.stable_entity_id(face), true] }

    shared_pairs = []
    seen_edges = {}
    faces.each do |face|
      face.edges.each do |edge|
        next unless edge&.valid? && edge.faces.length == 2

        edge_id = CORE.stable_entity_id(edge)
        next if seen_edges[edge_id]

        face_a, face_b = edge.faces
        next unless selected_ids[CORE.stable_entity_id(face_a)] &&
                    selected_ids[CORE.stable_entity_id(face_b)]

        seen_edges[edge_id] = true
        shared_pairs << [
          CORE.stable_entity_id(face_a),
          CORE.stable_entity_id(face_b),
          CORE.normal_angle_deg(face_a, face_b)
        ]
      end
    end

    puts '=' * 110
    puts '[COPLANAR FACE DIAG] SELECTED FACES'
    puts "faces=#{faces.length} shared_edges=#{shared_pairs.length}"
    puts "angle_tolerance=#{angle_tolerance_deg} deg plane_tolerance=#{plane_tolerance_mm} mm"
    if metrics
      puts format('all_selected_best_fit_max_dev=%.9f mm', metrics[:max_vertex_deviation_mm])
    else
      puts 'all_selected_best_fit=FAILED'
    end
    puts "normal_components=#{components.length}"
    components.each_with_index do |component, index|
      ids = component.map { |face| CORE.stable_entity_id(face) }
      puts "  N#{index + 1}: faces=#{component.length} PIDs=#{ids.inspect}"
    end
    puts "refined_groups=#{refined.length}"
    refined.each_with_index do |group, index|
      descriptor = CORE.describe_planar_group(group)
      puts format(
        '  P%d: faces=%d vertices=%d max_angle=%.9fdeg max_dev=%.9fmm PIDs=%s',
        index + 1,
        descriptor[:face_count],
        descriptor[:vertex_count],
        descriptor[:max_adjacent_angle_deg],
        descriptor[:max_vertex_deviation_mm],
        descriptor[:face_ids].inspect
      )
    end
    unless shared_pairs.empty?
      puts 'shared-edge pairs:'
      shared_pairs.each do |face_a_id, face_b_id, angle|
        puts format(
          '  F%s <-> F%s angle=%s %s',
          face_a_id,
          face_b_id,
          angle ? format('%.9fdeg', angle) : 'N/A',
          angle && angle <= angle_tolerance_deg ? 'PASS' : 'FAIL'
        )
      end
    end
    puts '=' * 110

    $lvn_coplanar_face_diagnostic = {
      faces: faces,
      components: components,
      refined_groups: refined,
      metrics: metrics,
      shared_pairs: shared_pairs
    }
    nil
  rescue StandardError => error
    puts '[COPLANAR FACE DIAG] FAILED'
    puts "#{error.class}: #{error.message}"
    puts Array(error.backtrace).first(20).join("\n")
    nil
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

  def print_report(report)
    puts '=' * 110
    puts '[COPLANAR FACE MERGE] COMPLETE'
    puts "solid=#{report[:solid_name]} PID=#{report[:solid_pid]}"
    puts "angle_tolerance=#{report[:angle_tolerance_deg]} deg"
    puts "best_fit_plane_tolerance=#{report[:plane_tolerance_mm]} mm"
    puts "source_faces=#{report[:source_face_count]}"
    puts "normal_components=#{report[:normal_component_count]} planar_groups=#{report[:planar_group_count]} singletons=#{report[:singleton_group_count]}"
    puts "merge_groups=#{report[:merge_group_count]} merged_input_faces=#{report[:merged_input_face_count]}"
    puts "face_reduction=#{report[:actual_face_reduction]} expected=#{report[:expected_face_reduction]}"
    puts "faces=#{report.dig(:initial_topology, :faces)} -> #{report.dig(:final_topology, :faces)}"
    puts "edges=#{report.dig(:initial_topology, :edges)} -> #{report.dig(:final_topology, :edges)}"
    puts "manifold=#{report[:initial_manifold]} -> #{report[:final_manifold]}"
    puts format('elapsed=%.3f s', report[:elapsed_sec].to_f)
    puts '=' * 110
  end
end

nil
