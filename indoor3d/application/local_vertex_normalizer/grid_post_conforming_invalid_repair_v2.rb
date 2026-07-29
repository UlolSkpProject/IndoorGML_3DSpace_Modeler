# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(:collapse_short_edge_sliver_triangles_before_post_conforming_invalid_repair_v2)
          alias_method :collapse_short_edge_sliver_triangles_before_post_conforming_invalid_repair_v2,
                       :collapse_short_edge_sliver_triangles
        end

        # The near-edge repair must see the mesh after exact grid conforming.
        # Before conforming, exact T-junctions can still appear as one long edge on
        # one triangle and split sub-edges on its neighbour. Treating those as
        # near-edge defects too early produces false candidates and degenerate local
        # flips. Keep the established altitude/source-Face fallback unchanged at its
        # original pre-conforming location, then run one second invalid-repair pass
        # here, immediately after grid conforming + short-edge handling and before
        # the exact hard gate.
        def collapse_short_edge_sliver_triangles(
          triangle_records,
          plan,
          baseline_validation
        )
          collapsed, sliver_report =
            collapse_short_edge_sliver_triangles_before_post_conforming_invalid_repair_v2(
              triangle_records,
              plan,
              baseline_validation
            )

          repaired, repair_report = repair_post_conforming_grid_invalids(collapsed)
          @grid_post_conforming_invalid_repair_stats_v2 = repair_report
          [repaired, sliver_report]
        end

        # Restore the original cbb6bc2 source-Face fallback at the earlier
        # normalize_triangle_records_allowing_collisions stage. The first near-edge
        # experiment wrapped this method and therefore ran before
        # conforming_triangle_snapshot; that ordering is intentionally disabled.
        def retriangulate_grid_invalid_source_faces(triangle_records)
          retriangulate_grid_invalid_source_faces_before_near_edge_split_v2(
            triangle_records
          )
        end

        def repair_post_conforming_grid_invalids(triangle_records)
          initial_invalid = grid_invalid_pair_signatures(triangle_records)
          if initial_invalid.empty?
            return [
              triangle_records,
              {
                policy: :post_conforming_source_face_then_near_edge,
                input_triangle_count: triangle_records.length,
                output_triangle_count: triangle_records.length,
                initial_invalid_pair_count: 0,
                final_invalid_pair_count: 0,
                invalid_pair_reduction: 0,
                accepted_source_face_count: 0,
                accepted_near_edge_count: 0,
                skipped: true,
                skip_reason: :no_invalid_pairs
              }
            ]
          end

          # First retry the generic source-Face reconstruction now that exact
          # vertex-on-edge incidences have been conformed. This is preferred over
          # bending any near edge because it can often remove a bad internal
          # triangulation while preserving the source Face boundary exactly.
          source_repaired, source_report =
            retriangulate_grid_invalid_source_faces_before_near_edge_split_v2(
              triangle_records
            )

          # Only residual invalid pairs are offered to the P-preserving near-edge
          # repair (owner flip first, then all-owner split). Every accepted candidate
          # still passes the unchanged exact topology/intersection checks.
          near_repaired, near_report = repair_grid_invalid_near_edge_splits(
            source_repaired
          )

          final_invalid = grid_invalid_pair_signatures(near_repaired)
          source_count = source_report[:accepted_face_count].to_i
          near_count = near_report[:accepted_split_count].to_i
          any_repair = source_count.positive? || near_count.positive?

          [
            near_repaired,
            {
              policy: :post_conforming_source_face_then_near_edge,
              input_triangle_count: triangle_records.length,
              output_triangle_count: near_repaired.length,
              initial_invalid_pair_count: initial_invalid.length,
              final_invalid_pair_count: final_invalid.length,
              invalid_pair_reduction: initial_invalid.length - final_invalid.length,
              accepted_source_face_count: source_count,
              accepted_near_edge_count: near_count,
              source_face_retriangulation: source_report,
              near_edge_repair: near_report,
              affected_source_face_keys: (
                Array(source_report[:affected_source_face_keys]) +
                Array(near_report[:affected_source_face_keys])
              ).compact.uniq,
              skipped: !any_repair,
              skip_reason: any_repair ? nil : :no_safe_post_conforming_repair
            }
          ]
        end
      end
    end
  end
end
