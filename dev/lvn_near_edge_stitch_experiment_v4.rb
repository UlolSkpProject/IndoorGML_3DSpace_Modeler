# frozen_string_literal: true

# v4: post-conforming exact-coplanar patch repair experiment.
#
# v3 proved that a two-owner host-edge operation is too local for ijn58ryq:
# after grid conforming, the shared host edge can belong to two triangles whose
# opposite apexes lie on the same side of that edge. That is an overlapping fan,
# not a valid convex quad, so an exact edge flip is correctly rejected.
#
# This experiment therefore moves the repair unit outward to the already proven
# production unit: same source_face + same exact-coplanar key + edge-connected
# component. The difference is POSITION: run it after grid conforming and the
# existing short-edge stage, immediately before the hard exact mesh gate.
#
# It is still intersection-triggered: if the post-conforming mesh has no exact
# invalid pair, nothing is changed.
#
# Production LVN files are untouched.

load File.join(__dir__, 'lvn_near_edge_stitch_experiment_v3.rb')

module LvnNearEdgeStitchExperiment
  class StitchNormalizer
    private

    def collapse_short_edge_sliver_triangles(records, plan, baseline_inventory)
      # Call production LVN implementation directly via super. The v1-v3
      # experimental method in this same subclass is replaced by this method.
      collapsed, short_edge_report = super

      initial_invalid = invalid_pair_signatures(collapsed)
      initial_low = low_altitude_signatures(collapsed)

      if initial_invalid.empty?
        @near_edge_stitch_report = {
          policy: :post_conforming_intersection_sliver_patch_retriangulation,
          threshold_mm: @tolerance_mm,
          input_triangle_count: collapsed.length,
          output_triangle_count: collapsed.length,
          initial_invalid_pair_count: 0,
          final_invalid_pair_count: 0,
          invalid_pair_reduction: 0,
          initial_low_altitude_count: initial_low.length,
          final_low_altitude_count: initial_low.length,
          accepted_stitch_count: 0,
          accepted_stitches: [],
          attempts: [],
          skipped: true,
          skip_reason: :no_invalid_intersections
        }
        return [collapsed, short_edge_report]
      end

      repaired, patch_report = retriangulate_grid_altitude_slivers(collapsed)
      final_invalid = invalid_pair_signatures(repaired)
      final_low = low_altitude_signatures(repaired)

      @near_edge_stitch_report = {
        policy: :post_conforming_intersection_sliver_patch_retriangulation,
        threshold_mm: @tolerance_mm,
        input_triangle_count: collapsed.length,
        output_triangle_count: repaired.length,
        initial_invalid_pair_count: initial_invalid.length,
        final_invalid_pair_count: final_invalid.length,
        invalid_pair_reduction: initial_invalid.length - final_invalid.length,
        initial_low_altitude_count: initial_low.length,
        final_low_altitude_count: final_low.length,
        accepted_stitch_count: patch_report[:accepted_patch_count].to_i,
        accepted_stitches: Array(patch_report[:accepted_patches]),
        attempts: Array(patch_report[:attempts]),
        skipped: patch_report[:accepted_patch_count].to_i.zero?,
        skip_reason: patch_report[:skip_reason],
        underlying_policy: patch_report[:policy],
        detected_sliver_count: patch_report[:detected_sliver_count],
        remaining_sliver_count: patch_report[:remaining_sliver_count],
        attempted_patch_count: patch_report[:attempted_patch_count],
        affected_source_face_keys: patch_report[:affected_source_face_keys]
      }

      [repaired, short_edge_report]
    end
  end
end

nil
