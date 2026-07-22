# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(:repair_degenerate_source_triangles_before_runtime_regression_v2)
          alias_method :repair_degenerate_source_triangles_before_runtime_regression_v2,
                       :repair_degenerate_source_triangles
        end

        # A zero-area polygon emitted by SketchUp's source Face mesh has no
        # surface area to preserve. If the local diagonal repair cannot resolve
        # it, remove only the zero-area/duplicate records and force every affected
        # source Face through step-6 coplanar patch reconstruction.
        def repair_degenerate_source_triangles(
          triangle_records,
          coordinate_space: :grid
        )
          degenerate_indices = triangle_records.each_index.select do |index|
            degenerate_triangle_record?(
              triangle_records[index],
              coordinate_space: coordinate_space
            )
          end
          failure_set = empty_repair_failure_set
          if degenerate_indices.empty?
            return [
              triangle_records,
              {
                repaired_triangles: 0,
                replaced_pairs: 0,
                repair_failure_set: finalize_repair_failure_set(failure_set)
              }
            ]
          end

          add_repair_failure!(
            failure_set,
            reason: :degenerate_triangle,
            triangle_indices: degenerate_indices,
            source_face_keys: degenerate_indices.map do |index|
              triangle_records[index][:source_face_key]
            end
          )
          failure_set = finalize_repair_failure_set(failure_set)

          repaired, report =
            repair_degenerate_source_triangles_before_runtime_regression_v2(
              triangle_records,
              coordinate_space: coordinate_space
            )
          [repaired, report.merge(repair_failure_set: failure_set)]
        rescue ReconstructionError => error
          raise unless coordinate_space == :source

          forced_face_keys = source_face_keys_with_adjacent_triangles(
            triangle_records,
            degenerate_indices,
            coordinate_space: :source
          )
          sanitized, cleanup = sanitize_source_triangle_records(triangle_records)
          forced_face_keys.concat(cleanup[:affected_source_face_keys])
          forced_face_keys.compact!
          forced_face_keys.uniq!
          forced_lookup = forced_face_keys.to_h { |key| [key, true] }
          sanitized = sanitized.map do |record|
            if forced_lookup[record[:source_face_key]]
              record.merge(force_retriangulation: true)
            else
              record
            end
          end

          if sanitized.empty?
            raise ReconstructionError,
                  "Source triangle fallback removed every triangle: #{error.message}"
          end

          [
            sanitized,
            {
              repaired_triangles: 0,
              replaced_pairs: 0,
              deferred_to_patch_retriangulation: true,
              fallback_reason: "#{error.class}: #{error.message}",
              forced_source_face_keys: forced_face_keys,
              removed_source_degenerate_triangles:
                cleanup[:removed_degenerate_triangle_count],
              removed_source_duplicate_triangles:
                cleanup[:removed_duplicate_triangle_count],
              repair_failure_set: failure_set
            }
          ]
        end

        def sanitize_source_triangle_records(triangle_records)
          signatures = {}
          affected_source_face_keys = []
          removed_degenerate = 0
          removed_duplicate = 0

          records = triangle_records.filter_map do |record|
            if degenerate_triangle_record?(record, coordinate_space: :source)
              removed_degenerate += 1
              affected_source_face_keys << record[:source_face_key]
              next
            end

            signature = triangle_signature_for_space(record[:points], :source)
            if signatures.key?(signature)
              removed_duplicate += 1
              affected_source_face_keys << record[:source_face_key]
              affected_source_face_keys << signatures[signature][:source_face_key]
              next
            end

            signatures[signature] = record
            record
          end

          [
            records,
            {
              removed_degenerate_triangle_count: removed_degenerate,
              removed_duplicate_triangle_count: removed_duplicate,
              affected_source_face_keys: affected_source_face_keys.compact.uniq
            }
          ]
        end

        unless private_method_defined?(:normalize_triangle_records_allowing_collisions_before_runtime_regression_v2)
          alias_method :normalize_triangle_records_allowing_collisions_before_runtime_regression_v2,
                       :normalize_triangle_records_allowing_collisions
        end

        # Propagate source-space fallback markers into the report consumed by
        # collect_forced_retriangulation_keys.
        def normalize_triangle_records_allowing_collisions(
          triangle_records,
          axis_plane_plan = nil,
          duplicate_diagnostics: nil
        )
          forced_face_keys = triangle_records.filter_map do |record|
            record[:source_face_key] if record[:force_retriangulation]
          end
          records, cleanup =
            normalize_triangle_records_allowing_collisions_before_runtime_regression_v2(
              triangle_records,
              axis_plane_plan,
              duplicate_diagnostics: duplicate_diagnostics
            )
          cleanup[:forced_source_face_keys] = (
            Array(cleanup[:forced_source_face_keys]) + forced_face_keys
          ).compact.uniq
          [records, cleanup]
        end
      end
    end
  end
end
