# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(
          :orient_and_merge_rebuilt_surface_before_validated_preservation_v2
        )
          alias_method(
            :orient_and_merge_rebuilt_surface_before_validated_preservation_v2,
            :orient_and_merge_rebuilt_surface
          )
        end

        # A rebuilt surface that already passed the post-rebuild hard checkpoint
        # must not be handed back to SketchUp's n-gon triangulator. Different
        # internal diagonals are acceptable when the exact patch planes and outer
        # or hole boundary loops are unchanged.
        def orient_and_merge_rebuilt_surface(entities, validated_triangles)
          unless rebuilt_surface_matches_validated_input?(
            entities,
            validated_triangles
          )
            return orient_and_merge_rebuilt_surface_before_validated_preservation_v2(
              entities,
              validated_triangles
            )
          end

          topology_before = geometry_counts(entities)
          consistency = repair_reverse_faces(entities)
          topology_after = geometry_counts(entities)

          unless closed_surface?(topology_after)
            return orient_and_merge_rebuilt_surface_before_validated_preservation_v2(
              entities,
              validated_triangles
            )
          end

          orientation = {
            reversed_faces: consistency[:reversed_faces].to_i,
            consistency_reversed_faces:
              consistency[:consistency_reversed_faces].to_i,
            shell_component_count: consistency[:component_count].to_i,
            outward_reversed_faces: consistency[:outward_reversed_faces].to_i,
            signed_volume_before_mm3:
              consistency[:signed_volume_before_in3].to_f * (MM_PER_INCH**3),
            signed_volume_after_mm3:
              consistency[:signed_volume_after_in3].to_f * (MM_PER_INCH**3),
            topology_before: topology_before,
            topology_after: topology_after,
            error: consistency[:error]
          }

          cleanup = empty_coplanar_cleanup_report(
            fallback_reason: :preserved_validated_surface
          )
          cleanup[:merged_faces] = 0
          cleanup[:preserved_constrained_edges] = true
          cleanup[:preserved_validated_triangle_complex] = true
          cleanup[:preserved_validated_surface] = true

          [orientation, cleanup]
        end

        def rebuilt_surface_matches_validated_input?(
          entities,
          validated_triangles
        )
          checkpoint = @validated_rebuild_surface_checkpoint
          if checkpoint &&
             checkpoint[:entities_object_id] == entities.object_id &&
             checkpoint[:validated_records_object_id] == validated_triangles.object_id
            return checkpoint[:surface_equivalent] == true
          end

          diagnostics = {}
          rebuilt = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: diagnostics
          )
          return false unless diagnostics[:duplicate_count].to_i.zero?

          rebuilt, = repair_degenerate_source_triangles(rebuilt)
          validate_normalized_triangle_mesh!(rebuilt)
          verify_normalized_surface_equivalence!(validated_triangles, rebuilt)
          true
        rescue Error, ArgumentError, StandardError
          false
        end
      end
    end
  end
end
