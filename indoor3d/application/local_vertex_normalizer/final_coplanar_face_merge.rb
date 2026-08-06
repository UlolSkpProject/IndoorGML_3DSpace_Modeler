# frozen_string_literal: true

require_relative 'coplanar_face_component_merge'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        FINAL_COPLANAR_FACE_PLANE_TOLERANCE_MM =
          CoplanarFaceComponentMerge::DEFAULT_PLANE_TOLERANCE_MM unless
            const_defined?(:FINAL_COPLANAR_FACE_PLANE_TOLERANCE_MM, false)
        FINAL_COPLANAR_FACE_ANGLE_TOLERANCE_DEG =
          CoplanarFaceComponentMerge::DEFAULT_ANGLE_TOLERANCE_DEG unless
            const_defined?(:FINAL_COPLANAR_FACE_ANGLE_TOLERANCE_DEG, false)

        private

        unless private_method_defined?(:normalize_entity_before_final_coplanar_face_merge)
          alias_method :normalize_entity_before_final_coplanar_face_merge,
                       :normalize_entity
        end

        # Append the exact same connected near-coplanar Face merge used by the
        # standalone geometry diagnostic. The geometry decision and acceptance gates
        # live only in CoplanarFaceComponentMerge.
        #
        # This wrapper adds rollback protection only: if that shared merge itself
        # raises, restore the already-successful normalized surface. It does not
        # apply a second, stricter equivalence policy to successful merges.
        def normalize_entity(entity)
          report = normalize_entity_before_final_coplanar_face_merge(entity)
          entities = entity.definition.entities

          baseline_triangles = snapshot_final_coplanar_baseline(entities)
          unless baseline_triangles
            attach_final_coplanar_skip_report(
              report,
              'Could not snapshot normalized surface before final coplanar Face merge'
            )
            return report
          end

          begin
            merge_report = CoplanarFaceComponentMerge.merge!(
              entity,
              plane_tolerance_mm: FINAL_COPLANAR_FACE_PLANE_TOLERANCE_MM,
              angle_tolerance_deg: FINAL_COPLANAR_FACE_ANGLE_TOLERANCE_DEG
            )
            merge_report[:applied] = merge_report[:merge_group_count].to_i.positive?
            merge_report[:restored] = false
            merge_report[:fallback_reason] = nil
            if report.is_a?(Hash)
              report[:final_coplanar_face_merge] = merge_report
              report[:collinear_vertex_removal_count] =
                report[:collinear_vertex_removal_count].to_i +
                merge_report[:collapsed_collinear_vertex_count].to_i
            end
          rescue StandardError => error
            restored = restore_final_coplanar_baseline!(
              entity,
              entities,
              baseline_triangles
            )

            if report.is_a?(Hash)
              report[:final_coplanar_face_merge] = {
                applied: false,
                restored: true,
                fallback_reason: "#{error.class}: #{error.message}",
                plane_tolerance_mm: FINAL_COPLANAR_FACE_PLANE_TOLERANCE_MM,
                angle_tolerance_deg: FINAL_COPLANAR_FACE_ANGLE_TOLERANCE_DEG,
                topology_after: restored[:topology],
                restored_surface_equivalence: restored[:surface_equivalence],
                restored_mesh_validation: restored[:mesh_validation],
                restored_triangle_cleanup: restored[:triangle_cleanup],
                restored_duplicate_diagnostics: restored[:duplicate_diagnostics],
                grid_residual_mm: restored[:grid_residual_mm]
              }
            end
          end

          report
        end

        def snapshot_final_coplanar_baseline(entities)
          duplicate_diagnostics = {}
          triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: duplicate_diagnostics,
            snapshot_role: :before_final_coplanar_face_merge
          )
          triangles, = discard_collapsed_triangle_records(triangles)
          validate_normalized_triangle_mesh!(triangles)
          triangles
        rescue StandardError
          nil
        end

        def attach_final_coplanar_skip_report(report, reason)
          return unless report.is_a?(Hash)

          report[:final_coplanar_face_merge] = {
            applied: false,
            restored: false,
            skipped: true,
            fallback_reason: reason,
            plane_tolerance_mm: FINAL_COPLANAR_FACE_PLANE_TOLERANCE_MM,
            angle_tolerance_deg: FINAL_COPLANAR_FACE_ANGLE_TOLERANCE_DEG
          }
        end

        def restore_final_coplanar_baseline!(entity, entities, baseline_triangles)
          erase_source_geometry(entities)
          restored = rebuild_triangles(entities, baseline_triangles)
          unless restored[:added_faces] == baseline_triangles.length &&
                 restored[:skipped_collinear].zero?
            raise ReconstructionError,
                  "Could not restore normalized surface after final coplanar " \
                  "Face merge failure: #{restored.inspect}"
          end

          repair_reverse_faces(entities)
          topology = geometry_counts(entities)
          validate_rebuilt_entity!(entity, topology)

          residual_mm = max_grid_residual_mm(geometry_vertices(entities))
          if residual_mm > GRID_EPSILON_MM
            raise TopologyChangedError,
                  "Restored normalized surface is off the #{@tolerance_mm} mm " \
                  "grid: residual=#{residual_mm} mm"
          end

          duplicate_diagnostics = {}
          triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: duplicate_diagnostics,
            snapshot_role: :restored_after_final_coplanar_face_merge_failure
          )
          triangles, triangle_cleanup = discard_collapsed_triangle_records(triangles)
          mesh_validation = validate_normalized_triangle_mesh!(triangles)
          surface_equivalence = verify_normalized_surface_equivalence!(
            baseline_triangles,
            triangles
          )

          {
            topology: topology,
            grid_residual_mm: residual_mm,
            duplicate_diagnostics: duplicate_diagnostics,
            triangle_cleanup: triangle_cleanup,
            mesh_validation: mesh_validation,
            surface_equivalence: surface_equivalence
          }
        end
      end
    end
  end
end
