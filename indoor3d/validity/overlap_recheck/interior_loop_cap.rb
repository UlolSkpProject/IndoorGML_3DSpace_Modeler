# frozen_string_literal: true

require_relative 'clipped_mesh_rechecker'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityClippedMeshRecheck
          class RebuildAnalyzer
            unless private_method_defined?(:cap_plane_without_interior_loop_decomposition)
              alias_method :cap_plane_without_interior_loop_decomposition,
                           :cap_plane
            end

            private

            def cap_plane(plane, segments, crop, mesh)
              result = cap_plane_without_interior_loop_decomposition(
                plane, segments, crop, mesh
              )
              return result unless result[:error].to_s ==
                                   'interior_plane_loop_requires_hole_triangulation'

              cap_plane_by_vertical_decomposition(plane, segments, crop, mesh)
            rescue StandardError => e
              cap_plane_error(
                segments,
                "interior_loop_decomposition_failed: #{e.class}: #{e.message}"
              )
            end

            def cap_plane_by_vertical_decomposition(plane, segments, crop, mesh)
              rectangle = plane_rectangle(plane, crop)
              min_u, max_u = [rectangle[0][0], rectangle[1][0]].minmax
              min_v, max_v = [rectangle[0][1], rectangle[3][1]].minmax

              rows = segments.filter_map do |a3, b3|
                a = project_plane(plane, a3).map(&:to_f)
                b = project_plane(plane, b3).map(&:to_f)
                next if squared_distance_2d(a, b) <= @weld * @weld

                { a: a, b: b }
              end

              crossing = first_proper_segment_crossing(rows)
              return cap_plane_error(
                segments,
                'interior_loop_decomposition_segment_crossing'
              ) if crossing

              u_breaks = cap_u_breaks(rows, min_u, max_u)
              return cap_plane_error(
                segments,
                'interior_loop_decomposition_no_slabs'
              ) if u_breaks.length < 2

              triangles = []
              classified_cell_count = 0
              inside_cell_count = 0
              ambiguous_cell_count = 0
              slab_count = 0
              skipped_narrow_slab_count = 0

              u_breaks.each_cons(2) do |u0, u1|
                if u1 - u0 <= @weld * 0.25
                  skipped_narrow_slab_count += 1
                  next
                end

                slab_count += 1
                u_mid = (u0 + u1) * 0.5
                boundaries = slab_boundaries(
                  rows, u0, u1, u_mid, min_v, max_v
                )
                unless slab_boundary_order_valid?(boundaries)
                  return cap_plane_error(
                    segments,
                    'interior_loop_decomposition_boundary_order_invalid'
                  )
                end

                boundaries.each_cons(2) do |lower, upper|
                  gap = upper[:v_mid] - lower[:v_mid]
                  next if gap <= @weld * 0.25

                  classified_cell_count += 1
                  sample2 = [
                    u_mid, (lower[:v_mid] + upper[:v_mid]) * 0.5
                  ]
                  sample3 = unproject_plane(plane, sample2, crop)
                  inside = point_inside_mesh(sample3, mesh)
                  if inside.nil?
                    ambiguous_cell_count += 1
                    return cap_plane_error(
                      segments,
                      'interior_loop_decomposition_classification_ambiguous'
                    )
                  end
                  next unless inside

                  polygon = [
                    [u0, lower[:v0]],
                    [u1, lower[:v1]],
                    [u1, upper[:v1]],
                    [u0, upper[:v0]]
                  ]
                  polygon = deduplicate_polygon_2d(polygon)
                  polygon = simplify_polygon(polygon)
                  next if polygon.length < 3

                  ears = triangulate_polygon(polygon)
                  return cap_plane_error(
                    segments,
                    'interior_loop_decomposition_ear_clipping_failed'
                  ) if ears.nil?

                  inside_cell_count += 1
                  ears.each do |triangle2|
                    next if triangle_area_2d_abs(triangle2) <= area_epsilon

                    triangle3 = triangle2.map do |point|
                      unproject_plane(plane, point, crop)
                    end
                    triangles << orient_cap_triangle(plane, triangle3)
                  end
                end
              end

              {
                triangles: triangles,
                report: {
                  'input_segment_count' => segments.length,
                  'decomposition_mode' => 'vertical_trapezoids',
                  'u_break_count' => u_breaks.length,
                  'slab_count' => slab_count,
                  'skipped_narrow_slab_count' =>
                    skipped_narrow_slab_count,
                  'classified_cell_count' => classified_cell_count,
                  'ambiguous_cell_count' => ambiguous_cell_count,
                  'inside_region_count' => inside_cell_count,
                  'inside_trapezoid_count' => inside_cell_count,
                  'cap_triangle_count' => triangles.length
                },
                error: nil
              }
            rescue StandardError => e
              cap_plane_error(
                segments,
                "interior_loop_decomposition_failed: #{e.class}: #{e.message}"
              )
            end

            def cap_u_breaks(rows, min_u, max_u)
              values = [min_u.to_f, max_u.to_f]
              rows.each do |row|
                values << clamp(row[:a][0], min_u, max_u)
                values << clamp(row[:b][0], min_u, max_u)
              end
              values.sort!

              clusters = []
              values.each do |value|
                if clusters.empty? ||
                   (value - clusters[-1][-1]).abs > @weld
                  clusters << [value]
                else
                  clusters[-1] << value
                end
              end
              representatives = clusters.map do |cluster|
                if cluster.any? { |value| near?(value, min_u) }
                  min_u.to_f
                elsif cluster.any? { |value| near?(value, max_u) }
                  max_u.to_f
                else
                  cluster.sum / cluster.length.to_f
                end
              end
              representatives.uniq.sort
            end

            def slab_boundaries(rows, u0, u1, u_mid, min_v, max_v)
              boundaries = [
                {
                  kind: :rectangle_min,
                  v0: min_v.to_f,
                  v1: min_v.to_f,
                  v_mid: min_v.to_f
                },
                {
                  kind: :rectangle_max,
                  v0: max_v.to_f,
                  v1: max_v.to_f,
                  v_mid: max_v.to_f
                }
              ]

              rows.each_with_index do |row, index|
                min_row_u, max_row_u = [row[:a][0], row[:b][0]].minmax
                next unless
                  u_mid > min_row_u + @weld * 0.1 &&
                  u_mid < max_row_u - @weld * 0.1

                v_mid = segment_v_at_u(row, u_mid)
                next if v_mid.nil?
                next if v_mid < min_v - @weld || v_mid > max_v + @weld

                boundaries << {
                  kind: :segment,
                  index: index,
                  v0: clamp(segment_v_at_u(row, u0), min_v, max_v),
                  v1: clamp(segment_v_at_u(row, u1), min_v, max_v),
                  v_mid: clamp(v_mid, min_v, max_v)
                }
              end

              boundaries.sort_by! do |boundary|
                [
                  boundary[:v_mid],
                  boundary[:kind] == :segment ? 0 : 1,
                  boundary[:index].to_i
                ]
              end
              collapse_coincident_slab_boundaries(boundaries)
            end

            def collapse_coincident_slab_boundaries(boundaries)
              result = []
              boundaries.each do |boundary|
                previous = result[-1]
                coincident = previous &&
                             (boundary[:v_mid] - previous[:v_mid]).abs <= @weld &&
                             (boundary[:v0] - previous[:v0]).abs <= @weld &&
                             (boundary[:v1] - previous[:v1]).abs <= @weld
                next if coincident

                result << boundary
              end
              result
            end

            def slab_boundary_order_valid?(boundaries)
              boundaries.each_cons(2).all? do |lower, upper|
                lower[:v_mid] <= upper[:v_mid] + @weld &&
                  lower[:v0] <= upper[:v0] + @weld * 2.0 &&
                  lower[:v1] <= upper[:v1] + @weld * 2.0
              end
            end

            def segment_v_at_u(row, u)
              a = row[:a]
              b = row[:b]
              delta_u = b[0] - a[0]
              return nil if delta_u.abs <= @weld * 0.1

              parameter = (u.to_f - a[0]) / delta_u
              a[1] + (b[1] - a[1]) * parameter
            end

            def deduplicate_polygon_2d(points)
              result = []
              points.each do |point|
                next if result.any? &&
                        squared_distance_2d(result[-1], point) <=
                          @weld * @weld

                result << point.map(&:to_f)
              end
              if result.length > 1 &&
                 squared_distance_2d(result[0], result[-1]) <= @weld * @weld
                result.pop
              end
              result
            end

            def triangle_area_2d_abs(triangle)
              a, b, c = triangle
              (cross_2d(
                subtract_2d(b, a), subtract_2d(c, a)
              ) * 0.5).abs
            end

            def first_proper_segment_crossing(rows)
              rows.each_with_index do |row1, index1|
                ((index1 + 1)...rows.length).each do |index2|
                  row2 = rows[index2]
                  next if segments_share_endpoint_2d?(row1, row2)
                  next unless proper_segment_crossing_2d?(
                    row1[:a], row1[:b], row2[:a], row2[:b]
                  )

                  return [index1, index2]
                end
              end
              nil
            end

            def segments_share_endpoint_2d?(row1, row2)
              [row1[:a], row1[:b]].any? do |point1|
                [row2[:a], row2[:b]].any? do |point2|
                  squared_distance_2d(point1, point2) <= @weld * @weld
                end
              end
            end

            def proper_segment_crossing_2d?(a, b, c, d)
              ab_c = cross_2d(subtract_2d(b, a), subtract_2d(c, a))
              ab_d = cross_2d(subtract_2d(b, a), subtract_2d(d, a))
              cd_a = cross_2d(subtract_2d(d, c), subtract_2d(a, c))
              cd_b = cross_2d(subtract_2d(d, c), subtract_2d(b, c))
              epsilon = area_epsilon
              ab_c * ab_d < -epsilon && cd_a * cd_b < -epsilon
            end

            def clamp(value, minimum, maximum)
              [[value.to_f, minimum.to_f].max, maximum.to_f].min
            end
          end
        end
      end
    end
  end
end
