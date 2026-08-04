# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_interior_loop_cap'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            unless private_method_defined?(:conforming_triangle_soup_without_exact_duplicate_repair)
              alias_method :conforming_triangle_soup_without_exact_duplicate_repair,
                           :conforming_triangle_soup
              alias_method :triangle_soup_topology_without_exact_duplicate_repair_report,
                           :triangle_soup_topology
            end

            private

            # Preserve every already-valid triangle soup unchanged. For an
            # invalid soup only, remove exact welded duplicate triangles and
            # accept the repaired soup exclusively when the existing
            # closed-two-manifold hard gate becomes true.
            def conforming_triangle_soup(triangles)
              conformed = conforming_triangle_soup_without_exact_duplicate_repair(
                triangles
              )
              @exact_duplicate_repair_report = nil

              original_topology =
                triangle_soup_topology_without_exact_duplicate_repair_report(
                  conformed
                )
              return conformed if original_topology['closed_two_manifold'] == true

              repaired, duplicate_group_count, removed_triangle_count =
                remove_exact_welded_duplicate_triangles(conformed)
              return conformed if removed_triangle_count.zero?

              repaired_topology =
                triangle_soup_topology_without_exact_duplicate_repair_report(
                  repaired
                )
              return conformed unless repaired_topology['closed_two_manifold'] == true

              @exact_duplicate_repair_report = {
                'exact_duplicate_triangle_repair_applied' => true,
                'exact_duplicate_triangle_group_count' => duplicate_group_count,
                'exact_duplicate_triangle_removed_count' => removed_triangle_count,
                'exact_duplicate_triangle_before_count' => conformed.length,
                'exact_duplicate_triangle_after_count' => repaired.length,
                'exact_duplicate_triangle_original_topology' => original_topology
              }
              repaired
            end

            def triangle_soup_topology(triangles)
              report =
                triangle_soup_topology_without_exact_duplicate_repair_report(
                  triangles
                )
              repair = @exact_duplicate_repair_report
              return report unless repair
              return report unless
                report['triangle_count'].to_i ==
                repair['exact_duplicate_triangle_after_count'].to_i

              report.merge(repair)
            end

            def remove_exact_welded_duplicate_triangles(triangles)
              flattened = triangles.flatten(1)
              welding = weld_endpoints(flattened)
              point_cluster = welding.fetch(:point_cluster)

              seen = {}
              duplicate_groups = Hash.new(0)
              repaired = []

              triangles.each_with_index do |triangle, triangle_index|
                offset = triangle_index * 3
                vertex_ids = 3.times.map do |corner|
                  point_cluster.fetch(offset + corner)
                end

                # Degenerate input remains under the original topology gate.
                if vertex_ids.uniq.length < 3
                  repaired << triangle
                  next
                end

                key = vertex_ids.sort.freeze
                if seen.key?(key)
                  duplicate_groups[key] += 1
                  next
                end

                seen[key] = true
                repaired << triangle
              end

              removed_triangle_count = triangles.length - repaired.length
              duplicate_group_count = duplicate_groups.length
              [repaired, duplicate_group_count, removed_triangle_count]
            end
          end
        end
      end
    end
  end
end
