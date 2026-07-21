# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        class RebuiltSurfaceCheckpointError < StandardError; end unless
          const_defined?(:RebuiltSurfaceCheckpointError, false)

        private

        unless private_method_defined?(:normalized_triangle_snapshot_before_rebuild_checkpoint_v2)
          alias_method(
            :normalized_triangle_snapshot_before_rebuild_checkpoint_v2,
            :normalized_triangle_snapshot
          )
        end

        unless private_method_defined?(:verify_triangle_rebuild_before_surface_checkpoint_v2!)
          alias_method(
            :verify_triangle_rebuild_before_surface_checkpoint_v2!,
            :verify_triangle_rebuild!
          )
        end

        # Capture the readback diagnostics that belong to the triangle records
        # passed immediately afterward to verify_triangle_rebuild!.
        def normalized_triangle_snapshot(entities, duplicate_diagnostics:)
          records = normalized_triangle_snapshot_before_rebuild_checkpoint_v2(
            entities,
            duplicate_diagnostics: duplicate_diagnostics
          )
          @last_normalized_triangle_snapshot_checkpoint = {
            entities_object_id: entities.object_id,
            duplicate_count: duplicate_diagnostics[:duplicate_count].to_i,
            duplicate_samples: Array(duplicate_diagnostics[:samples]).first(10)
          }
          records
        end

        # SketchUp may legally return a different internal diagonal for the same
        # planar patch. Exact triangle equality remains the preferred result, but
        # an alternative triangulation is accepted only when the rebuilt records
        # already passed mesh validation and describe the exact same patch planes
        # and boundary loops. A different surface escapes pipeline_v2's legacy
        # record-only rescue and therefore rolls the whole operation back before
        # orientation, coplanar cleanup, or entity repair can run.
        def verify_triangle_rebuild!(expected_records, actual_records)
          snapshot = @last_normalized_triangle_snapshot_checkpoint || {}
          if snapshot[:duplicate_count].to_i.positive?
            raise RebuiltSurfaceCheckpointError,
                  "Rebuilt surface checkpoint found duplicate triangle faces: " \
                  "count=#{snapshot[:duplicate_count]} " \
                  "samples=#{snapshot[:duplicate_samples].inspect}"
          end

          exact_error = nil
          begin
            verify_triangle_rebuild_before_surface_checkpoint_v2!(
              expected_records,
              actual_records
            )
          rescue Error, ArgumentError => error
            exact_error = error
          end

          surface_equivalence = nil
          unless exact_error
            surface_equivalence = {
              equivalent: true,
              strategy: :exact_triangle_complex
            }
          else
            begin
              surface_equivalence = verify_normalized_surface_equivalence!(
                expected_records,
                actual_records
              ).merge(strategy: :equivalent_surface_retriangulation)
            rescue Error, ArgumentError => surface_error
              raise RebuiltSurfaceCheckpointError,
                    "Rebuilt surface checkpoint failed before post-processing: " \
                    "exact=#{exact_error.class}: #{exact_error.message}; " \
                    "surface=#{surface_error.class}: #{surface_error.message}"
            end
          end

          @validated_rebuild_surface_checkpoint = {
            entities_object_id: snapshot[:entities_object_id],
            validated_records_object_id: expected_records.object_id,
            validated_records: expected_records.map(&:dup),
            surface_equivalent: true,
            exact_triangle_match: exact_error.nil?,
            exact_triangle_error:
              exact_error && "#{exact_error.class}: #{exact_error.message}",
            surface_equivalence: surface_equivalence
          }
          true
        end
      end
    end
  end
end
