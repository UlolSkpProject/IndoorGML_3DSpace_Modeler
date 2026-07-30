# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(:normalize_entity_before_normalized_input_fast_path_v2)
          alias_method :normalize_entity_before_normalized_input_fast_path_v2,
                       :normalize_entity
        end

        # Already-normalized B-reps do not need to be projected to the same grid,
        # rebuilt, and then simplified again. Keep this path deliberately strict:
        # - the public normalized? policy must already accept the entity;
        # - the current SketchUp shell must still be closed/manifold;
        # - an exact normalized triangle snapshot must require no cleanup;
        # - the unchanged triangle mesh must pass the existing exact hard gate.
        #
        # Any uncertainty falls back to the established full pipeline. The outer
        # final_coplanar_face_merge_v2 wrapper still runs unchanged after this
        # method returns.
        def normalize_entity(entity)
          return normalize_entity_before_normalized_input_fast_path_v2(entity) unless
            normalized_input_fast_path_candidate_v2?(entity)

          ensure_unique_definition(entity)
          result = try_normalized_input_fast_path_v2(entity)
          return result if result

          normalize_entity_before_normalized_input_fast_path_v2(entity)
        end

        def normalized_input_fast_path_candidate_v2?(entity)
          return false unless normalized?(entity)

          entities = entity.definition.entities
          topology = geometry_counts(entities)
          return false unless closed_topology?(topology)
          return false unless entity.respond_to?(:manifold?) && entity.manifold?

          true
        rescue StandardError
          false
        end

        def try_normalized_input_fast_path_v2(entity)
          entities = entity.definition.entities
          topology = geometry_counts(entities)
          vertices = geometry_vertices(entities)
          residual_mm = max_grid_residual_mm(vertices)
          return normalized_input_fast_path_fallback_v2(:grid_residual) if
            residual_mm > GRID_EPSILON_MM

          duplicate_diagnostics = {}
          triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: duplicate_diagnostics,
            snapshot_role: :normalized_input_fast_path
          )
          triangles, cleanup = discard_collapsed_triangle_records(triangles)

          return normalized_input_fast_path_fallback_v2(:triangle_cleanup_required) if
            normalized_input_fast_path_cleanup_required_v2?(cleanup)
          return normalized_input_fast_path_fallback_v2(:duplicate_triangle_cleanup_required) if
            duplicate_diagnostics[:duplicate_count].to_i.positive?

          mesh_validation = validate_normalized_triangle_mesh!(triangles)

          # Re-check the live B-rep immediately before taking the fast path. No
          # geometry has been mutated, but keeping the gate here makes the scope
          # explicit and protects future callers/refactors.
          current_topology = geometry_counts(entities)
          return normalized_input_fast_path_fallback_v2(:topology_changed_during_probe) unless
            current_topology == topology
          return normalized_input_fast_path_fallback_v2(:not_closed_after_probe) unless
            closed_topology?(current_topology)
          return normalized_input_fast_path_fallback_v2(:not_manifold_after_probe) unless
            entity.respond_to?(:manifold?) && entity.manifold?

          @normalized_input_fast_path_baseline_v2 = {
            entities_object_id: entities.object_id,
            topology: current_topology.dup,
            triangles: triangles
          }

          report = build_normalized_input_fast_path_report_v2(
            entity,
            topology: current_topology,
            vertices: vertices,
            triangles: triangles,
            mesh_validation: mesh_validation,
            residual_mm: residual_mm
          )

          emit_normalized_input_fast_path_work_v2(
            applied: true,
            reason: :already_normalized_exactly_validated,
            triangle_count: triangles.length
          )
          report
        rescue Error, ArgumentError => error
          normalized_input_fast_path_fallback_v2(
            :exact_validation_rejected,
            error: error
          )
        rescue StandardError => error
          normalized_input_fast_path_fallback_v2(
            :probe_error,
            error: error
          )
        end

        def normalized_input_fast_path_cleanup_required_v2?(cleanup)
          cleanup[:removed_coincident_triangle_count].to_i.positive? ||
            cleanup[:removed_collinear_triangle_count].to_i.positive? ||
            cleanup[:removed_duplicate_triangle_count].to_i.positive?
        end

        def normalized_input_fast_path_fallback_v2(reason, error: nil)
          @normalized_input_fast_path_baseline_v2 = nil
          emit_normalized_input_fast_path_work_v2(
            applied: false,
            reason: reason,
            error: error
          )
          nil
        end

        def build_normalized_input_fast_path_report_v2(
          entity,
          topology:,
          vertices:,
          triangles:,
          mesh_validation:,
          residual_mm:
        )
          vertex_metrics = normalized_vertex_metrics(vertices, nil)
          axis_plane_plan = disabled_axis_plane_normalization_plan
          short_edge_plan = short_edge_sliver_collapse_plan(entity.definition.entities, nil)
          short_edge_report = short_edge_plan.merge(
            removed_degenerate_triangle_count: 0,
            removed_duplicate_triangle_count: 0,
            euler_characteristic_before: triangle_mesh_euler_characteristic(mesh_validation),
            euler_characteristic_after: triangle_mesh_euler_characteristic(mesh_validation)
          )
          triangle_cleanup = {
            removed_coincident_triangle_count: 0,
            removed_collinear_triangle_count: 0,
            removed_duplicate_triangle_count: 0,
            affected_source_face_keys: [],
            stages: {},
            repaired_triangles: 0,
            replaced_pairs: 0
          }
          duplicate_diagnostics = {
            source: { duplicate_count: 0, samples: [] },
            source_conforming: { duplicate_count: 0, samples: [] },
            grid_conforming: { duplicate_count: 0, samples: [] },
            rebuilt: { duplicate_count: 0, samples: [] },
            final: { duplicate_count: 0, samples: [] }
          }
          orientation = {
            reversed_faces: 0,
            consistency_reversed_faces: 0,
            shell_component_count: mesh_validation[:component_count].to_i,
            outward_reversed_faces: 0,
            signed_volume_before_mm3: solid_volume_mm3(entity),
            signed_volume_after_mm3: solid_volume_mm3(entity)
          }
          axis_plane_merge = {
            removed_edges: 0,
            merged_faces: 0,
            passes: 0
          }
          build = {
            added_faces: 0,
            skipped_collinear: 0
          }

          report = build_normalization_report(
            entity: entity,
            topology_before: topology,
            topology_after: topology,
            volume_before_mm3: solid_volume_mm3(entity),
            source_vertices: vertices,
            final_vertices: vertices,
            vertex_metrics: vertex_metrics,
            source_triangles: triangles,
            conforming_triangles: triangles,
            degenerate_repair: triangle_cleanup,
            build: build,
            mesh_validation: mesh_validation,
            final_mesh_validation: mesh_validation,
            orientation: orientation,
            axis_plane_plan: axis_plane_plan,
            axis_plane_merge: axis_plane_merge,
            short_edge_sliver_repair: short_edge_report,
            duplicate_diagnostics: duplicate_diagnostics,
            residual_mm: residual_mm
          )

          report[:normalization_strategy] = :already_normalized_fast_path_v2
          report[:normalization_fast_path] = {
            applied: true,
            reason: :already_normalized_exactly_validated,
            skipped_grid_projection: true,
            skipped_triangle_rebuild: true,
            skipped_orient_and_coplanar_cleanup: true,
            exact_hard_gate_preserved: true,
            final_coplanar_face_merge_preserved: true,
            validated_triangle_count: triangles.length
          }
          report[:target_collision_count] = vertex_metrics[:target_collision_count].to_i
          report[:merged_target_vertex_count] = vertex_metrics[:merged_target_vertex_count].to_i
          report[:target_collision_samples] = Array(vertex_metrics[:target_collisions])
          report[:target_collision_cleanup] = empty_triangle_cleanup_report
          report[:collapsed_triangle_cleanup] = triangle_cleanup
          report[:rebuilt_pre_repair_validation] = {
            valid: true,
            skipped: true,
            reason: :already_normalized_input
          }
          report[:final_surface_equivalence] = {
            equivalent: true,
            skipped: true,
            reason: :geometry_unchanged_before_final_coplanar_merge
          }
          report[:final_entity_repair] = {
            attempted: false,
            manifold: true,
            initial_topology: topology,
            final_topology: topology
          }
          report[:source_boundary_normalization] = {}
          report[:source_collapsed_sliver_cleanup] = {}
          report[:grid_altitude_sliver_retriangulation] = {
            skipped: true,
            skip_reason: :already_normalized_input,
            detected_sliver_count: 0,
            attempted_patch_count: 0,
            accepted_patch_count: 0
          }
          report[:manifold] = true
          report
        end

        def emit_normalized_input_fast_path_work_v2(
          applied:,
          reason:,
          triangle_count: nil,
          error: nil
        )
          return unless @local_vertex_normalizer_debug_profile

          fields = [
            "applied=#{applied ? 1 : 0}",
            "reason=#{reason}",
            "triangles=#{triangle_count || 0}"
          ]
          if error
            fields << "error=#{error.class}:#{error.message.to_s.gsub(/\s+/, ' ')[0, 160]}"
          end
          puts "[LVN DEBUG] WORK normalized_input_fast_path #{fields.join(' ')}"
        rescue StandardError
          nil
        end
      end
    end
  end
end
