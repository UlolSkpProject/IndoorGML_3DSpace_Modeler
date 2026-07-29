# frozen_string_literal: true

# Diagnostic-only wrapper for the post-conforming residual altitude-sliver repair.
# It does not change candidate selection or geometry policy.
#
# SketchUp Ruby Console:
#   load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_post_conforming_sliver_probe.rb'
#   LvnPostConformingSliverProbe.run

root = File.expand_path('..', __dir__)
require File.join(root, 'indoor3d', 'application', 'local_vertex_normalizer') unless
  defined?(ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer)
load File.join(root, 'dev', 'lvn_normalize_selected_solids.rb') unless
  defined?(LvnNormalizeSelectedSolids)

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(:repair_post_conforming_grid_altitude_slivers_before_probe_v2)
          alias_method :repair_post_conforming_grid_altitude_slivers_before_probe_v2,
                       :repair_post_conforming_grid_altitude_slivers

          def repair_post_conforming_grid_altitude_slivers(triangle_records)
            repaired, report =
              repair_post_conforming_grid_altitude_slivers_before_probe_v2(
                triangle_records
              )

            puts format(
              '[LVN POST SLIVER PROBE] slivers=%s->%s cavities=%s/%s invalid=%s->%s skipped=%s reason=%s',
              report[:initial_sliver_count],
              report[:final_sliver_count],
              report[:accepted_cavity_count],
              report[:attempted_cavity_count],
              report[:initial_invalid_pair_count],
              report[:final_invalid_pair_count],
              report[:skipped],
              report[:skip_reason]
            )
            Array(report[:attempts]).first(16).each_with_index do |attempt, index|
              puts format(
                '[LVN POST SLIVER PROBE] attempt=%d accepted=%s reason=%s face=%s seeds=%s ring=%s triangles=%s slivers=%s->%s low=%s->%s min=%s->%s invalid=%s->%s new=%s removed=%s error=%s',
                index + 1,
                attempt[:accepted],
                attempt[:reason],
                attempt[:source_face_key],
                attempt[:seed_indices].inspect,
                attempt[:ring],
                attempt[:patch_triangle_count],
                attempt[:before_sliver_count],
                attempt[:after_sliver_count],
                attempt[:before_low_altitude_count],
                attempt[:after_low_altitude_count],
                attempt[:before_minimum_altitude_mm],
                attempt[:after_minimum_altitude_mm],
                attempt[:before_invalid_pair_count],
                attempt[:after_invalid_pair_count],
                attempt[:new_invalid_pair_count],
                attempt[:removed_invalid_pair_count],
                attempt[:error]
              )
            end

            [repaired, report]
          end
        end
      end
    end
  end
end

module LvnPostConformingSliverProbe
  module_function

  def run(
    tolerance_mm: ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
  )
    puts '[LVN POST SLIVER PROBE] diagnostic wrapper installed; geometry policy unchanged'
    LvnNormalizeSelectedSolids.run(tolerance_mm: tolerance_mm)
    nil
  end
end

nil
