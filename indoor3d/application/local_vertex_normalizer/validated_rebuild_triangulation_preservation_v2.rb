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

        # A rebuilt triangle complex that exactly matches the already validated
        # in-memory complex must not be handed back to SketchUp's n-gon
        # triangulator. Removing its coplanar internal edges can recreate
        # diagonals that cross adjacent surfaces even though the input triangles
        # passed the exact topology and intersection hard gate.
        def orient_and_merge_rebuilt_surface(entities, validated_triangles)
          unless rebuilt_triangle_complex_matches_validated_input?(
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
            fallback_reason: :preserved_validated_triangle_complex
          )
          cleanup[:merged_faces] = 0
          cleanup[:preserved_constrained_edges] = true
          cleanup[:preserved_validated_triangle_complex] = true

          [orientation, cleanup]
        end

        def rebuilt_triangle_complex_matches_validated_input?(
          entities,
          validated_triangles
        )
          diagnostics = {}
          rebuilt = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: diagnostics
          )
          return false unless diagnostics[:duplicate_count].to_i.zero?

          expected = validated_triangles.map do |record|
            canonical_triangle_key(
              record[:points].map { |point| grid_indices(point) }
            )
          end.sort
          actual = rebuilt.map do |record|
            canonical_triangle_key(
              record[:points].map { |point| grid_indices(point) }
            )
          end.sort

          expected == actual
        rescue Error, ArgumentError, StandardError
          false
        end
      end
    end
  end
end
