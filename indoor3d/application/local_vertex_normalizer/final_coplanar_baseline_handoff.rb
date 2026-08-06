# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Reuses the exact, already-validated final triangle records as the
      # rollback baseline for final_coplanar_face_merge. The handoff is valid
      # only inside the same normalize_entity call and falls back to the existing
      # independent snapshot whenever any scope, entity, topology, manifold, or
      # grid check is uncertain.
      module LocalVertexNormalizerFinalCoplanarBaselineHandoff
        HANDOFF_ROLES = [
          :post_coplanar_cleanup,
          :final_fallback,
          :normalized_input_fast_path
        ].freeze
        RESIDUAL_MATCH_TOLERANCE_MM = 1.0e-12

        private

        def normalize_entity(entity)
          previous_context = @final_coplanar_baseline_handoff_context
          context = {
            token: Object.new,
            entity: entity,
            entity_object_id: entity.object_id,
            handoff: nil,
            selection: nil,
            capture_error: nil
          }
          @final_coplanar_baseline_handoff_context = context

          report = super
          attach_final_coplanar_baseline_handoff_report(report, context)
          report
        ensure
          @final_coplanar_baseline_handoff_context = previous_context
        end

        def final_normalized_mesh_state(
          entities,
          expected_triangles,
          final_repair,
          topology_after,
          post_cleanup_snapshot,
          duplicate_diagnostics
        )
          result = super
          context = @final_coplanar_baseline_handoff_context
          return result unless context && result.is_a?(Array)

          reuse_decision = result[4]
          role = if reuse_decision.is_a?(Hash) && reuse_decision[:reused]
                   :post_coplanar_cleanup
                 else
                   :final_fallback
                 end
          capture_final_coplanar_baseline_handoff(
            context,
            context[:entity],
            entities,
            result[0],
            topology: topology_after,
            role: role
          )
          result
        end

        def try_normalized_input_fast_path(entity)
          result = super
          return result unless result

          context = @final_coplanar_baseline_handoff_context
          baseline = @normalized_input_fast_path_baseline
          return result unless context && baseline.is_a?(Hash)

          capture_final_coplanar_baseline_handoff(
            context,
            entity,
            entity.definition.entities,
            baseline[:triangles],
            topology: baseline[:topology],
            role: :normalized_input_fast_path
          )
          result
        end

        def snapshot_final_coplanar_baseline(entities)
          context = @final_coplanar_baseline_handoff_context
          return super unless context

          handoff = context[:handoff]
          validation = validate_final_coplanar_baseline_handoff(
            context,
            handoff,
            entities
          )
          if validation[:rejection_reasons].empty?
            context[:selection] = {
              reused: true,
              role: handoff[:role],
              triangle_count: handoff[:triangles].length,
              rejection_reasons: [],
              fallback_snapshot_available: nil
            }
            return handoff[:triangles]
          end

          baseline = super
          context[:selection] = {
            reused: false,
            role: handoff && handoff[:role],
            triangle_count: baseline ? baseline.length : 0,
            rejection_reasons: validation[:rejection_reasons],
            fallback_snapshot_available: !baseline.nil?,
            validation_error: validation[:validation_error]
          }
          baseline
        end

        def capture_final_coplanar_baseline_handoff(
          context,
          entity,
          entities,
          triangles,
          topology:,
          role:
        )
          return false unless context.equal?(
            @final_coplanar_baseline_handoff_context
          )
          return false unless context[:entity_object_id] == entity.object_id
          return false unless HANDOFF_ROLES.include?(role)
          return false unless triangles.is_a?(Array) && !triangles.empty?

          current_topology = geometry_counts(entities)
          return false unless topology == current_topology

          residual_mm = max_grid_residual_mm(geometry_vertices(entities))
          return false unless residual_mm.finite?
          return false if residual_mm > final_coplanar_grid_epsilon_mm

          context[:handoff] = {
            scope_token: context[:token],
            entity_object_id: entity.object_id,
            entities_object_id: entities.object_id,
            topology: current_topology.dup,
            grid_residual_mm: residual_mm,
            role: role,
            triangles: triangles,
            validated: true
          }
          true
        rescue StandardError => error
          context[:capture_error] = "#{error.class}: #{error.message}"
          false
        end

        def validate_final_coplanar_baseline_handoff(
          context,
          handoff,
          entities
        )
          reasons = []
          unless handoff.is_a?(Hash)
            reasons << :handoff_missing
            return { rejection_reasons: reasons, validation_error: nil }
          end

          reasons << :scope_token_mismatch unless
            handoff[:scope_token].equal?(context[:token])
          reasons << :entity_mismatch unless
            handoff[:entity_object_id] == context[:entity_object_id]
          reasons << :entities_mismatch unless
            handoff[:entities_object_id] == entities.object_id
          reasons << :candidate_not_validated unless handoff[:validated] == true
          reasons << :candidate_role_invalid unless
            HANDOFF_ROLES.include?(handoff[:role])
          reasons << :candidate_triangles_missing unless
            handoff[:triangles].is_a?(Array) && !handoff[:triangles].empty?

          current_topology = geometry_counts(entities)
          reasons << :topology_changed unless handoff[:topology] == current_topology
          reasons << :topology_not_closed unless closed_topology?(current_topology)

          entity = context[:entity]
          if entity.respond_to?(:manifold?)
            reasons << :entity_not_manifold unless entity.manifold? == true
          else
            reasons << :manifold_status_unavailable
          end

          candidate_residual = handoff[:grid_residual_mm]
          if !candidate_residual.respond_to?(:finite?) || !candidate_residual.finite?
            reasons << :candidate_grid_residual_missing
          elsif candidate_residual > final_coplanar_grid_epsilon_mm
            reasons << :candidate_grid_residual_exceeds_epsilon
          end

          current_residual = max_grid_residual_mm(geometry_vertices(entities))
          if !current_residual.finite?
            reasons << :current_grid_residual_missing
          elsif current_residual > final_coplanar_grid_epsilon_mm
            reasons << :current_grid_residual_exceeds_epsilon
          elsif candidate_residual.respond_to?(:finite?) && candidate_residual.finite? &&
                (candidate_residual - current_residual).abs >
                  RESIDUAL_MATCH_TOLERANCE_MM
            reasons << :grid_residual_changed
          end

          { rejection_reasons: reasons, validation_error: nil }
        rescue StandardError => error
          {
            rejection_reasons: reasons + [:handoff_validation_error],
            validation_error: "#{error.class}: #{error.message}"
          }
        end

        def final_coplanar_grid_epsilon_mm
          self.class.const_get(:GRID_EPSILON_MM)
        end

        def attach_final_coplanar_baseline_handoff_report(report, context)
          selection = context[:selection] || {
            reused: false,
            role: context.dig(:handoff, :role),
            triangle_count: 0,
            rejection_reasons: [:baseline_selection_not_reached],
            fallback_snapshot_available: nil
          }
          summary = selection.merge(
            capture_error: context[:capture_error],
            exact_hard_gate_preserved: true,
            fallback_snapshot_preserved: true
          )
          report[:final_coplanar_baseline_handoff] = summary if
            report.is_a?(Hash)

          profile = @local_vertex_normalizer_diagnostic_profile
          profile[:final_coplanar_baseline_handoff] = summary.dup if
            profile.is_a?(Hash)
        rescue StandardError
          nil
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerFinalCoplanarBaselineHandoff unless
          ancestors.include?(
            LocalVertexNormalizerFinalCoplanarBaselineHandoff
          )
      end
    end
  end
end
