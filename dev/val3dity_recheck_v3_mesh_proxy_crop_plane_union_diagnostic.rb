# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_crop_plane_union_repair'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            unless private_method_defined?(:union_crop_plane_triangles_without_diagnostic)
              alias_method :union_crop_plane_triangles_without_diagnostic,
                           :union_crop_plane_triangles
            end

            private

            # Diagnostic replacement for the silent conservative repair path.
            # It preserves the same acceptance rule: only a repaired soup that
            # passes the existing closed-two-manifold hard gate is returned.
            # Failed attempts return the original soup and only add report data.
            def conforming_triangle_soup(triangles)
              @crop_plane_union_diagnostic_rows = []
              @crop_plane_union_repair_report = nil

              original =
                conforming_triangle_soup_without_crop_plane_union_repair(
                  triangles
                )
              original_topology =
                triangle_soup_topology_without_crop_plane_union_repair_report(
                  original
                )

              return original if original_topology['closed_two_manifold'] == true

              report = {
                'crop_plane_union_repair_attempted' => false,
                'crop_plane_union_repair_applied' => false,
                'crop_plane_union_repair_outcome' => nil,
                'crop_plane_union_repair_input_triangle_count' =>
                  triangles.length,
                'crop_plane_union_repair_original_triangle_count' =>
                  original.length,
                'crop_plane_union_repair_original_topology' =>
                  original_topology,
                'crop_plane_union_repair_plane_attempts' =>
                  @crop_plane_union_diagnostic_rows
              }

              unless crop_plane_union_repair_candidate?(original_topology)
                report['crop_plane_union_repair_outcome'] = 'not_candidate'
                return crop_plane_union_diagnostic_return(
                  report, original, original
                )
              end

              crop = @crop_plane_union_repair_crop
              unless crop
                report['crop_plane_union_repair_outcome'] = 'crop_unavailable'
                return crop_plane_union_diagnostic_return(
                  report, original, original
                )
              end

              report['crop_plane_union_repair_attempted'] = true
              repaired_raw, plane_reports =
                rebuild_crop_plane_triangle_unions(triangles, crop)
              report['crop_plane_union_repair_plane_attempts'] =
                @crop_plane_union_diagnostic_rows
              report['crop_plane_union_repair_planes'] = plane_reports

              unless repaired_raw
                report['crop_plane_union_repair_outcome'] =
                  'plane_union_build_failed'
                return crop_plane_union_diagnostic_return(
                  report, original, original
                )
              end

              if plane_reports.empty?
                report['crop_plane_union_repair_outcome'] =
                  'no_multi_triangle_crop_plane'
                return crop_plane_union_diagnostic_return(
                  report, original, original
                )
              end

              report['crop_plane_union_repair_raw_triangle_count'] =
                repaired_raw.length
              repaired =
                conforming_triangle_soup_without_crop_plane_union_repair(
                  repaired_raw
                )
              repaired_topology =
                triangle_soup_topology_without_crop_plane_union_repair_report(
                  repaired
                )
              report['crop_plane_union_repair_repaired_triangle_count'] =
                repaired.length
              report['crop_plane_union_repair_repaired_topology'] =
                repaired_topology

              if repaired_topology['closed_two_manifold'] == true
                report['crop_plane_union_repair_applied'] = true
                report['crop_plane_union_repair_outcome'] = 'applied'
                return crop_plane_union_diagnostic_return(
                  report, repaired, repaired
                )
              end

              report['crop_plane_union_repair_outcome'] =
                'repaired_topology_open'
              crop_plane_union_diagnostic_return(
                report, original, original
              )
            rescue StandardError => e
              report ||= {
                'crop_plane_union_repair_attempted' => true,
                'crop_plane_union_repair_applied' => false
              }
              report['crop_plane_union_repair_outcome'] = 'exception'
              report['crop_plane_union_repair_error'] =
                "#{e.class}: #{e.message}"
              report['crop_plane_union_repair_plane_attempts'] =
                @crop_plane_union_diagnostic_rows || []
              crop_plane_union_diagnostic_return(
                report,
                original || triangles,
                original || triangles
              )
            end

            def union_crop_plane_triangles(plane, triangles, crop)
              result = union_crop_plane_triangles_without_diagnostic(
                plane, triangles, crop
              )
              (@crop_plane_union_diagnostic_rows ||= []) << {
                'plane' => plane.to_s,
                'input_triangle_count' => triangles.length,
                'error' => result[:error],
                'report' => result[:report],
                'output_triangle_count' =>
                  Array(result[:triangles]).length
              }
              result
            rescue StandardError => e
              (@crop_plane_union_diagnostic_rows ||= []) << {
                'plane' => plane.to_s,
                'input_triangle_count' => triangles.length,
                'error' => "#{e.class}: #{e.message}",
                'report' => nil,
                'output_triangle_count' => 0
              }
              raise
            end

            def triangle_soup_topology(triangles)
              report =
                triangle_soup_topology_without_crop_plane_union_repair_report(
                  triangles
                )
              repair = @crop_plane_union_repair_report
              return report unless repair
              return report unless
                report['triangle_count'].to_i ==
                repair['crop_plane_union_repair_returned_triangle_count'].to_i

              report.merge(repair)
            end

            def crop_plane_union_diagnostic_return(report, returned, value)
              report['crop_plane_union_repair_returned_triangle_count'] =
                returned.length
              @crop_plane_union_repair_report = report
              value
            end
          end
        end
      end
    end
  end
end
