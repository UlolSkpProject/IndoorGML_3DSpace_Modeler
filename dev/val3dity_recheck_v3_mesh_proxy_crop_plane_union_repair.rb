# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_interior_loop_cap'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            unless private_method_defined?(:rebuild_geometry_without_crop_plane_union_repair)
              alias_method :rebuild_geometry_without_crop_plane_union_repair,
                           :rebuild_geometry
              alias_method :conforming_triangle_soup_without_crop_plane_union_repair,
                           :conforming_triangle_soup
              alias_method :triangle_soup_topology_without_crop_plane_union_repair_report,
                           :triangle_soup_topology
            end

            private

            # Keep the currently evaluated crop box available to the conservative
            # repair attempted by conforming_triangle_soup. Existing successful
            # geometry returns before the repair path and is therefore unchanged.
            def rebuild_geometry(mesh, crop)
              previous_crop = @crop_plane_union_repair_crop
              @crop_plane_union_repair_crop = crop
              rebuild_geometry_without_crop_plane_union_repair(mesh, crop)
            ensure
              @crop_plane_union_repair_crop = previous_crop
            end

            # A failed soup with no boundary edges but one or more non-manifold
            # edges can be caused by overlapping triangulations on a crop plane.
            # Rebuild only those crop-plane triangles as their planar union, then
            # rerun the existing conforming subdivision and hard topology gate.
            # The repair is accepted only when the unchanged hard gate reports a
            # closed two-manifold result.
            def conforming_triangle_soup(triangles)
              original =
                conforming_triangle_soup_without_crop_plane_union_repair(
                  triangles
                )
              @crop_plane_union_repair_report = nil

              original_topology =
                triangle_soup_topology_without_crop_plane_union_repair_report(
                  original
                )
              return original if original_topology['closed_two_manifold'] == true
              return original unless crop_plane_union_repair_candidate?(
                original_topology
              )

              crop = @crop_plane_union_repair_crop
              return original unless crop

              repaired_raw, plane_reports =
                rebuild_crop_plane_triangle_unions(triangles, crop)
              return original unless repaired_raw
              return original if plane_reports.empty?

              repaired =
                conforming_triangle_soup_without_crop_plane_union_repair(
                  repaired_raw
                )
              repaired_topology =
                triangle_soup_topology_without_crop_plane_union_repair_report(
                  repaired
                )
              return original unless
                repaired_topology['closed_two_manifold'] == true

              @crop_plane_union_repair_report = {
                'crop_plane_union_repair_applied' => true,
                'crop_plane_union_repair_original_triangle_count' =>
                  original.length,
                'crop_plane_union_repair_repaired_triangle_count' =>
                  repaired.length,
                'crop_plane_union_repair_original_topology' =>
                  original_topology,
                'crop_plane_union_repair_planes' => plane_reports
              }
              repaired
            rescue StandardError => e
              @crop_plane_union_repair_report = {
                'crop_plane_union_repair_applied' => false,
                'crop_plane_union_repair_error' =>
                  "#{e.class}: #{e.message}"
              }
              original || triangles
            end

            def triangle_soup_topology(triangles)
              report =
                triangle_soup_topology_without_crop_plane_union_repair_report(
                  triangles
                )
              repair = @crop_plane_union_repair_report
              return report unless repair
              return report unless repair['crop_plane_union_repair_applied'] == true
              return report unless
                report['triangle_count'].to_i ==
                repair['crop_plane_union_repair_repaired_triangle_count'].to_i

              report.merge(repair)
            end

            def crop_plane_union_repair_candidate?(topology)
              topology['boundary_edge_count'].to_i.zero? &&
                topology['non_manifold_edge_count'].to_i.positive? &&
                topology['degenerate_triangle_count'].to_i.zero?
            end

            def rebuild_crop_plane_triangle_unions(triangles, crop)
              groups = Hash.new { |hash, key| hash[key] = [] }
              retained = []

              triangles.each_with_index do |triangle, index|
                plane = triangle_crop_plane(triangle, crop)
                if plane
                  groups[plane] << [index, triangle]
                else
                  retained << triangle
                end
              end

              reports = {}
              rebuilt_plane_triangles = []
              groups.each do |plane, rows|
                if rows.length < 2
                  rebuilt_plane_triangles.concat(rows.map(&:last))
                  next
                end

                union_result = union_crop_plane_triangles(
                  plane,
                  rows.map(&:last),
                  crop
                )
                return [nil, {}] if union_result[:error]

                reports[plane.to_s] = union_result.fetch(:report)
                rebuilt_plane_triangles.concat(
                  union_result.fetch(:triangles)
                )
              end

              return [nil, {}] if reports.empty?

              [retained + rebuilt_plane_triangles, reports]
            end

            def triangle_crop_plane(triangle, crop)
              PLANES.each do |plane, axis, side|
                coordinate = crop.fetch(side).fetch(axis)
                return plane if triangle.all? do |point|
                  (point.fetch(axis).to_f - coordinate.to_f).abs <= @weld * 2.0
                end
              end
              nil
            end

            def union_crop_plane_triangles(plane, triangles, crop)
              projected = triangles.map do |triangle|
                triangle.map do |point|
                  project_plane(plane, point).map(&:to_f)
                end
              end
              return crop_plane_union_error(
                plane, triangles, 'projected_triangle_degenerate'
              ) if projected.any? do |triangle|
                triangle_area_2d_abs(triangle) <= area_epsilon
              end

              u_breaks = crop_plane_union_u_breaks(projected)
              return crop_plane_union_error(
                plane, triangles, 'insufficient_u_breaks'
              ) if u_breaks.length < 2

              union_triangles_2d = []
              slab_count = 0
              component_count = 0

              u_breaks.each_cons(2) do |u0, u1|
                next if u1 - u0 <= crop_plane_union_numeric_epsilon

                u_mid = (u0 + u1) * 0.5
                intervals = projected.filter_map do |triangle|
                  crop_plane_union_interval(triangle, u_mid)
                end
                next if intervals.empty?

                slab_count += 1
                crop_plane_union_components(intervals).each do |component|
                  polygon = crop_plane_union_component_polygon(
                    component, u0, u1
                  )
                  next if polygon.length < 3

                  ears = triangulate_polygon(polygon)
                  return crop_plane_union_error(
                    plane, triangles, 'union_ear_clipping_failed'
                  ) if ears.nil?

                  component_count += 1
                  ears.each do |triangle2|
                    next if triangle_area_2d_abs(triangle2) <= area_epsilon

                    union_triangles_2d << triangle2
                  end
                end
              end

              return crop_plane_union_error(
                plane, triangles, 'union_triangle_empty'
              ) if union_triangles_2d.empty?
              return crop_plane_union_error(
                plane, triangles, 'union_verification_failed'
              ) unless crop_plane_union_verified?(
                projected, union_triangles_2d
              )

              output = union_triangles_2d.map do |triangle2|
                triangle3 = triangle2.map do |point|
                  unproject_plane(plane, point, crop)
                end
                orient_cap_triangle(plane, triangle3)
              end

              input_area = projected.sum do |triangle|
                triangle_area_2d_abs(triangle)
              end
              output_area = union_triangles_2d.sum do |triangle|
                triangle_area_2d_abs(triangle)
              end

              {
                triangles: output,
                report: {
                  'mode' => 'crop_plane_triangle_union_vertical_sweep',
                  'input_triangle_count' => triangles.length,
                  'output_triangle_count' => output.length,
                  'u_break_count' => u_breaks.length,
                  'slab_count' => slab_count,
                  'union_component_count' => component_count,
                  'input_triangle_area_sum' => input_area,
                  'output_union_area' => output_area,
                  'overlap_area_removed' => [input_area - output_area, 0.0].max
                },
                error: nil
              }
            rescue StandardError => e
              crop_plane_union_error(
                plane,
                triangles,
                "#{e.class}: #{e.message}"
              )
            end

            def crop_plane_union_error(plane, triangles, error)
              {
                triangles: triangles,
                report: {
                  'mode' => 'crop_plane_triangle_union_vertical_sweep',
                  'input_triangle_count' => triangles.length,
                  'output_triangle_count' => triangles.length,
                  'error' => error.to_s
                },
                error: "#{plane}: #{error}"
              }
            end

            def crop_plane_union_u_breaks(projected)
              values = projected.flatten(1).map { |point| point[0].to_f }
              edges = projected.flat_map do |triangle|
                3.times.map do |index|
                  [triangle[index], triangle[(index + 1) % 3]]
                end
              end

              edges.each_with_index do |left, index|
                ((index + 1)...edges.length).each do |other_index|
                  intersection_u = crop_plane_union_intersection_u(
                    left[0], left[1],
                    edges[other_index][0], edges[other_index][1]
                  )
                  values << intersection_u if intersection_u
                end
              end

              crop_plane_union_cluster_values(values)
            end

            def crop_plane_union_intersection_u(a, b, c, d)
              r = subtract_2d(b, a)
              s = subtract_2d(d, c)
              denominator = cross_2d(r, s)
              epsilon = crop_plane_union_numeric_epsilon
              return nil if denominator.abs <= epsilon

              c_minus_a = subtract_2d(c, a)
              t = cross_2d(c_minus_a, s) / denominator
              u = cross_2d(c_minus_a, r) / denominator
              return nil if t < -epsilon || t > 1.0 + epsilon
              return nil if u < -epsilon || u > 1.0 + epsilon

              a[0].to_f + r[0] * [[t, 0.0].max, 1.0].min
            end

            def crop_plane_union_cluster_values(values)
              sorted = values.map(&:to_f).sort
              epsilon = crop_plane_union_numeric_epsilon
              clusters = []
              sorted.each do |value|
                if clusters.empty? || (value - clusters[-1][-1]).abs > epsilon
                  clusters << [value]
                else
                  clusters[-1] << value
                end
              end
              clusters.map { |cluster| cluster.sum / cluster.length.to_f }
            end

            def crop_plane_union_interval(triangle, u_mid)
              hits = []
              3.times do |index|
                a = triangle[index]
                b = triangle[(index + 1) % 3]
                delta_u = b[0].to_f - a[0].to_f
                next if delta_u.abs <= crop_plane_union_numeric_epsilon

                min_u, max_u = [a[0].to_f, b[0].to_f].minmax
                next unless u_mid > min_u && u_mid < max_u

                parameter = (u_mid - a[0].to_f) / delta_u
                v = a[1].to_f + (b[1].to_f - a[1].to_f) * parameter
                hits << {
                  edge: [a, b],
                  v_mid: v
                }
              end
              hits.sort_by! { |hit| hit[:v_mid] }
              hits = crop_plane_union_unique_hits(hits)
              return nil if hits.length < 2

              {
                lower: hits.first,
                upper: hits.last,
                lower_mid: hits.first[:v_mid],
                upper_mid: hits.last[:v_mid]
              }
            end

            def crop_plane_union_unique_hits(hits)
              epsilon = crop_plane_union_numeric_epsilon
              hits.each_with_object([]) do |hit, result|
                next if result.any? &&
                        (hit[:v_mid] - result[-1][:v_mid]).abs <= epsilon

                result << hit
              end
            end

            def crop_plane_union_components(intervals)
              epsilon = crop_plane_union_numeric_epsilon
              sorted = intervals.sort_by do |interval|
                [interval[:lower_mid], interval[:upper_mid]]
              end
              components = []

              sorted.each do |interval|
                if components.empty? ||
                   interval[:lower_mid] >
                     components[-1][:upper_mid] + epsilon
                  components << {
                    intervals: [interval],
                    lower_mid: interval[:lower_mid],
                    upper_mid: interval[:upper_mid]
                  }
                else
                  component = components[-1]
                  component[:intervals] << interval
                  component[:lower_mid] = [
                    component[:lower_mid], interval[:lower_mid]
                  ].min
                  component[:upper_mid] = [
                    component[:upper_mid], interval[:upper_mid]
                  ].max
                end
              end
              components
            end

            def crop_plane_union_component_polygon(component, u0, u1)
              lower = component[:intervals].min_by do |interval|
                interval[:lower_mid]
              end.fetch(:lower)
              upper = component[:intervals].max_by do |interval|
                interval[:upper_mid]
              end.fetch(:upper)

              polygon = [
                [u0, crop_plane_union_edge_v(lower.fetch(:edge), u0)],
                [u1, crop_plane_union_edge_v(lower.fetch(:edge), u1)],
                [u1, crop_plane_union_edge_v(upper.fetch(:edge), u1)],
                [u0, crop_plane_union_edge_v(upper.fetch(:edge), u0)]
              ]
              polygon = crop_plane_union_deduplicate_polygon(polygon)
              simplify_polygon(polygon)
            end

            def crop_plane_union_edge_v(edge, u)
              a, b = edge
              delta_u = b[0].to_f - a[0].to_f
              raise 'vertical union boundary edge' if
                delta_u.abs <= crop_plane_union_numeric_epsilon

              parameter = (u.to_f - a[0].to_f) / delta_u
              a[1].to_f + (b[1].to_f - a[1].to_f) * parameter
            end

            def crop_plane_union_deduplicate_polygon(points)
              epsilon_squared = crop_plane_union_numeric_epsilon**2
              result = []
              points.each do |point|
                next if result.any? &&
                        squared_distance_2d(result[-1], point) <=
                          epsilon_squared

                result << point.map(&:to_f)
              end
              if result.length > 1 &&
                 squared_distance_2d(result[0], result[-1]) <=
                   epsilon_squared
                result.pop
              end
              result
            end

            def crop_plane_union_verified?(input_triangles, output_triangles)
              input_samples = input_triangles.flat_map do |triangle|
                crop_plane_union_triangle_samples(triangle)
              end
              output_samples = output_triangles.flat_map do |triangle|
                crop_plane_union_triangle_samples(triangle)
              end

              input_covered = input_samples.all? do |point|
                output_triangles.any? do |triangle|
                  point_in_triangle_2d?(point, *triangle)
                end
              end
              output_inside = output_samples.all? do |point|
                input_triangles.any? do |triangle|
                  point_in_triangle_2d?(point, *triangle)
                end
              end
              input_covered && output_inside
            end

            def crop_plane_union_triangle_samples(triangle)
              centroid = [
                triangle.sum { |point| point[0].to_f } / 3.0,
                triangle.sum { |point| point[1].to_f } / 3.0
              ]
              edge_midpoints = 3.times.map do |index|
                a = triangle[index]
                b = triangle[(index + 1) % 3]
                [
                  (a[0].to_f + b[0].to_f) * 0.5,
                  (a[1].to_f + b[1].to_f) * 0.5
                ]
              end
              [centroid, *edge_midpoints]
            end

            def crop_plane_union_numeric_epsilon
              [@weld * 1.0e-6, 1.0e-12].max
            end
          end
        end
      end
    end
  end
end
