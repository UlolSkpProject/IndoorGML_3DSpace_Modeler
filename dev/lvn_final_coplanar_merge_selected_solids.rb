# frozen_string_literal: true

# Runs only the production final connected n-gon coplanar Face merge on every
# selected manifold solid. The preceding LocalVertexNormalizer stages are not run.
#
# This runner intentionally reuses the production final merge implementation in
# final_coplanar_face_merge.rb instead of keeping a second copy of the geometry
# algorithm in dev/.
#
# Each selected solid is handled in its own SketchUp operation. Any failure aborts
# that target's operation, so the original geometry is preserved.
#
# SketchUp Ruby Console:
#   load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_final_coplanar_merge_selected_solids.rb'
#   LvnFinalCoplanarMergeSelectedSolids.run

root = File.expand_path('..', __dir__)
require File.join(root, 'indoor3d', 'application', 'local_vertex_normalizer') unless
  defined?(ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer)

module LvnFinalCoplanarMergeSelectedSolids
  LVN = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer

  module_function

  def run(
    plane_tolerance_mm: LVN::FINAL_COPLANAR_FACE_PLANE_TOLERANCE_MM,
    angle_tolerance_deg: LVN::FINAL_COPLANAR_FACE_ANGLE_TOLERANCE_DEG
  )
    model = Sketchup.active_model
    selected = model.selection.to_a
    solids = selected.select { |entity| manifold_solid?(entity) }

    if solids.empty?
      puts '[LVN FINAL COPLANAR MERGE] selected manifold solids=0'
      return nil
    end

    plane_tolerance_mm = Float(plane_tolerance_mm)
    angle_tolerance_deg = Float(angle_tolerance_deg)
    raise ArgumentError, 'plane_tolerance_mm must be >= 0' if plane_tolerance_mm.negative?
    raise ArgumentError, 'angle_tolerance_deg must be >= 0' if angle_tolerance_deg.negative?

    result = {
      selected_count: selected.length,
      candidate_count: solids.length,
      success_count: 0,
      failure_count: 0,
      plane_tolerance_mm: plane_tolerance_mm,
      angle_tolerance_deg: angle_tolerance_deg,
      successes: [],
      failures: []
    }

    solids.each_with_index do |entity, index|
      identity = entity_identity(entity)
      operation_started = false

      begin
        operation_started = model.start_operation('LVN final coplanar Face merge', true)
        raise 'Could not start SketchUp operation' unless operation_started

        normalizer = LVN.new(LVN::DEFAULT_TOLERANCE_MM, model: model)

        # Match normalize behavior for ComponentInstances: do not alter siblings.
        normalizer.send(:ensure_unique_definition, entity)
        entities = entity.definition.entities

        topology_before = normalizer.send(:geometry_counts, entities)
        unless normalizer.send(:manifold_entity_with_closed_topology?, entity, topology_before)
          raise LVN::TopologyChangedError,
                "Final coplanar Face merge requires a closed manifold solid: #{identity[:name]} #{topology_before.inspect}"
        end

        baseline_residual_mm = normalizer.send(
          :max_grid_residual_mm,
          normalizer.send(:geometry_vertices, entities)
        )
        if baseline_residual_mm > LVN::GRID_EPSILON_MM
          raise LVN::TopologyChangedError,
                "Standalone final merge expects an already-normalized grid surface: residual=#{baseline_residual_mm} mm"
        end

        baseline_duplicate_diagnostics = {}
        baseline_triangles = normalizer.send(
          :normalized_triangle_snapshot,
          entities,
          duplicate_diagnostics: baseline_duplicate_diagnostics,
          snapshot_role: :before_standalone_final_coplanar_face_merge
        )
        baseline_triangles, baseline_cleanup = normalizer.send(
          :discard_collapsed_triangle_records,
          baseline_triangles
        )
        baseline_mesh_validation = normalizer.send(
          :validate_normalized_triangle_mesh!,
          baseline_triangles
        )

        merge_report = normalizer.send(
          :merge_final_coplanar_face_components!,
          entity,
          entities,
          plane_tolerance_mm: plane_tolerance_mm,
          angle_tolerance_deg: angle_tolerance_deg
        )

        topology_after = normalizer.send(:geometry_counts, entities)
        normalizer.send(:validate_rebuilt_entity!, entity, topology_after)

        final_residual_mm = normalizer.send(
          :max_grid_residual_mm,
          normalizer.send(:geometry_vertices, entities)
        )
        if final_residual_mm > LVN::GRID_EPSILON_MM
          raise LVN::TopologyChangedError,
                "Final coplanar Face merge moved vertices off grid: residual=#{final_residual_mm} mm"
        end

        final_duplicate_diagnostics = {}
        final_triangles = normalizer.send(
          :normalized_triangle_snapshot,
          entities,
          duplicate_diagnostics: final_duplicate_diagnostics,
          snapshot_role: :after_standalone_final_coplanar_face_merge
        )
        final_triangles, final_cleanup = normalizer.send(
          :discard_collapsed_triangle_records,
          final_triangles
        )
        final_mesh_validation = normalizer.send(
          :validate_normalized_triangle_mesh!,
          final_triangles
        )
        surface_equivalence = normalizer.send(
          :verify_normalized_surface_equivalence!,
          baseline_triangles,
          final_triangles
        )

        committed = model.commit_operation
        raise 'SketchUp returned false from commit_operation' if committed == false
        operation_started = false

        entry = identity.merge(
          topology_before: topology_before,
          topology_after: topology_after,
          baseline_grid_residual_mm: baseline_residual_mm,
          final_grid_residual_mm: final_residual_mm,
          baseline_triangle_cleanup: baseline_cleanup,
          final_triangle_cleanup: final_cleanup,
          baseline_mesh_validation: baseline_mesh_validation,
          final_mesh_validation: final_mesh_validation,
          surface_equivalence: surface_equivalence,
          merge: merge_report
        )
        result[:successes] << entry
        result[:success_count] += 1

        puts format(
          '[LVN FINAL COPLANAR MERGE] %d/%d OK   %s PID=%s groups=%d faces=%d->%d edges=%d->%d',
          index + 1,
          solids.length,
          identity[:name],
          identity[:pid],
          merge_report[:merge_group_count].to_i,
          topology_before[:faces],
          topology_after[:faces],
          topology_before[:edges],
          topology_after[:edges]
        )
      rescue StandardError => error
        model.abort_operation if operation_started

        result[:failure_count] += 1
        result[:failures] << identity.merge(
          error_class: error.class.to_s,
          error_message: error.message.to_s,
          backtrace: Array(error.backtrace).first(20)
        )

        warn format(
          '[LVN FINAL COPLANAR MERGE] %d/%d FAIL %s PID=%s | %s: %s',
          index + 1,
          solids.length,
          identity[:name],
          identity[:pid],
          error.class,
          error.message
        )
      end
    end

    $lvn_final_coplanar_merge_selected_solids = result

    puts '-' * 92
    puts format(
      '[LVN FINAL COPLANAR MERGE] solids=%d success=%d failure=%d plane_tol=%.6fmm angle_tol=%.6fdeg',
      result[:candidate_count],
      result[:success_count],
      result[:failure_count],
      plane_tolerance_mm,
      angle_tolerance_deg
    )
    puts '-' * 92

    nil
  end

  def manifold_solid?(entity)
    entity&.valid? &&
      entity.respond_to?(:definition) &&
      entity.respond_to?(:manifold?) &&
      entity.manifold? == true
  rescue StandardError
    false
  end

  def entity_identity(entity)
    {
      pid: (entity.persistent_id rescue nil),
      name: entity_display_name(entity),
      entity_class: entity.class.to_s
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
end

nil
