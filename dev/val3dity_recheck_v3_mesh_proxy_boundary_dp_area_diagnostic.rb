# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_boundary_dp_repair'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            unless private_method_defined?(:boundary_dp_conforming_triangle_soup_without_area_diagnostic)
              alias_method :boundary_dp_conforming_triangle_soup_without_area_diagnostic,
                           :boundary_ear_conforming_triangle_soup
              alias_method :boundary_ear_area_preserved_without_dp_area_diagnostic,
                           :boundary_ear_area_preserved?
            end

            private

            # Dev-only instrumentation. It preserves the existing DP repair
            # decision and augments only failed area-check reports.
            def boundary_ear_conforming_triangle_soup(triangles)
              @boundary_dp_area_diagnostic = nil
              @boundary_dp_weld_clusters = boundary_dp_area_weld_clusters(triangles)

              repaired, detail =
                boundary_dp_conforming_triangle_soup_without_area_diagnostic(
                  triangles
                )
              detail = detail || {}
              failure = detail['boundary_dp_failure']
              if failure && failure['stage'] == 'area_check' &&
                 @boundary_dp_area_diagnostic
                detail = detail.merge(
                  'boundary_dp_failure' => failure.merge(
                    'area_diagnostic' => @boundary_dp_area_diagnostic
                  )
                )
              end
              [repaired, detail]
            ensure
              @boundary_dp_weld_clusters = nil
            end

            def boundary_ear_area_preserved?(source_triangle, triangles)
              passed = boundary_ear_area_preserved_without_dp_area_diagnostic(
                source_triangle,
                triangles
              )
              unless passed
                @boundary_dp_area_diagnostic =
                  boundary_dp_build_area_diagnostic(
                    source_triangle,
                    triangles
                  )
              end
              passed
            end

            def boundary_dp_area_weld_clusters(triangles)
              points = triangles.flatten(1)
              welding = weld_endpoints(points)
              welding.fetch(:clusters).each_with_index.map do |cluster, index|
                representative = cluster.fetch(:representative).map(&:to_f)
                members = cluster.fetch(:members).map do |member|
                  member.map(&:to_f)
                end
                {
                  'cluster_index' => index,
                  'representative_in' => boundary_dp_round_point(representative),
                  'representative_mm' => boundary_dp_point_mm(representative),
                  'member_count' => members.length,
                  'diameter_in' => Math.sqrt(
                    cluster.fetch(:diameter_squared).to_f
                  ).round(15),
                  'diameter_mm' => (
                    Math.sqrt(cluster.fetch(:diameter_squared).to_f) * 25.4
                  ).round(12),
                  'source_indices' => Array(cluster[:source_indices]),
                  'members' => members.map do |member|
                    {
                      'point_in' => boundary_dp_round_point(member),
                      'point_mm' => boundary_dp_point_mm(member),
                      'shift_to_representative_in' => Math.sqrt(
                        squared_distance(member, representative)
                      ).round(15),
                      'shift_to_representative_mm' => (
                        Math.sqrt(squared_distance(member, representative)) * 25.4
                      ).round(12)
                    }
                  end
                }
              end
            end

            def boundary_dp_build_area_diagnostic(source_triangle, triangles)
              source_area = boundary_dp_triangle_area(source_triangle)
              output_areas = triangles.map do |triangle|
                boundary_dp_triangle_area(triangle)
              end
              output_area = output_areas.sum
              absolute_delta = (source_area - output_area).abs
              relative_delta = source_area.positive? ?
                absolute_delta / source_area : nil
              tolerance = [
                source_area * 1.0e-8,
                @weld * @weld * 10.0,
                1.0e-18
              ].max

              output_points = triangles.flatten(1)
              unique_output_points = []
              output_points.each do |point|
                next if unique_output_points.any? do |existing|
                  squared_distance(existing, point) <= @weld * @weld
                end

                unique_output_points << point
              end

              {
                'source_area_in2' => source_area.round(15),
                'source_area_mm2' => (source_area * 25.4 * 25.4).round(9),
                'output_area_in2' => output_area.round(15),
                'output_area_mm2' => (output_area * 25.4 * 25.4).round(9),
                'absolute_area_delta_in2' => absolute_delta.round(15),
                'absolute_area_delta_mm2' =>
                  (absolute_delta * 25.4 * 25.4).round(12),
                'relative_area_delta' => relative_delta&.round(15),
                'allowed_tolerance_in2' => tolerance.round(15),
                'allowed_tolerance_mm2' =>
                  (tolerance * 25.4 * 25.4).round(12),
                'delta_to_tolerance_ratio' =>
                  tolerance.positive? ? (absolute_delta / tolerance).round(9) : nil,
                'weld_tolerance_in' => @weld.to_f.round(15),
                'weld_tolerance_mm' => (@weld.to_f * 25.4).round(12),
                'source_triangle' =>
                  boundary_dp_triangle_diagnostic(source_triangle),
                'output_triangles' => triangles.each_with_index.map do |triangle, index|
                  {
                    'index' => index,
                    'area_in2' => output_areas.fetch(index).round(15),
                    'area_mm2' =>
                      (output_areas.fetch(index) * 25.4 * 25.4).round(9),
                    'triangle' => boundary_dp_triangle_diagnostic(triangle)
                  }
                end,
                'output_vertices' => unique_output_points.map do |point|
                  boundary_dp_output_point_diagnostic(point, source_triangle)
                end
              }
            end

            def boundary_dp_triangle_diagnostic(triangle)
              normal = cross(
                subtract(triangle[1], triangle[0]),
                subtract(triangle[2], triangle[0])
              )
              {
                'points_in' => triangle.map { |point| boundary_dp_round_point(point) },
                'points_mm' => triangle.map { |point| boundary_dp_point_mm(point) },
                'normal' => normal.map { |value| value.to_f.round(15) },
                'double_area_in2' => Math.sqrt(
                  magnitude_squared(normal)
                ).round(15)
              }
            end

            def boundary_dp_output_point_diagnostic(point, source_triangle)
              edge_rows = 3.times.map do |edge_index|
                a = source_triangle.fetch(edge_index)
                b = source_triangle.fetch((edge_index + 1) % 3)
                boundary_dp_point_edge_diagnostic(point, a, b, edge_index)
              end
              nearest = edge_rows.min_by do |row|
                [row['distance_in'], row['edge_index']]
              end
              corner_distances = source_triangle.each_with_index.map do |corner, index|
                distance = Math.sqrt(squared_distance(point, corner))
                {
                  'corner_index' => index,
                  'distance_in' => distance.round(15),
                  'distance_mm' => (distance * 25.4).round(12)
                }
              end
              cluster = boundary_dp_find_weld_cluster(point)

              {
                'point_in' => boundary_dp_round_point(point),
                'point_mm' => boundary_dp_point_mm(point),
                'source_corner' => corner_distances.any? do |row|
                  row['distance_in'].to_f <= @weld
                end,
                'corner_distances' => corner_distances,
                'source_plane_distance_in' =>
                  boundary_dp_point_plane_distance(point, source_triangle).round(15),
                'source_plane_distance_mm' => (
                  boundary_dp_point_plane_distance(point, source_triangle) * 25.4
                ).round(12),
                'nearest_edge_index' => nearest['edge_index'],
                'nearest_edge_distance_in' => nearest['distance_in'],
                'nearest_edge_distance_mm' => nearest['distance_mm'],
                'nearest_edge_parameter_raw' => nearest['parameter_raw'],
                'nearest_edge_parameter_clamped' => nearest['parameter_clamped'],
                'edge_diagnostics' => edge_rows,
                'weld_cluster' => cluster
              }
            end

            def boundary_dp_point_edge_diagnostic(point, a, b, edge_index)
              ab = subtract(b, a)
              length_squared = magnitude_squared(ab)
              if length_squared <= 1.0e-30
                return {
                  'edge_index' => edge_index,
                  'degenerate_edge' => true,
                  'distance_in' => Float::INFINITY,
                  'distance_mm' => Float::INFINITY
                }
              end

              parameter = dot(subtract(point, a), ab) / length_squared
              clamped = [[parameter, 0.0].max, 1.0].min
              projected = 3.times.map do |axis|
                a[axis].to_f + ab[axis] * clamped
              end
              distance = Math.sqrt(squared_distance(point, projected))
              {
                'edge_index' => edge_index,
                'degenerate_edge' => false,
                'parameter_raw' => parameter.round(15),
                'parameter_clamped' => clamped.round(15),
                'parameter_inside_open_segment' =>
                  parameter.positive? && parameter < 1.0,
                'projected_point_in' => boundary_dp_round_point(projected),
                'projected_point_mm' => boundary_dp_point_mm(projected),
                'distance_in' => distance.round(15),
                'distance_mm' => (distance * 25.4).round(12),
                'within_weld_tolerance' => distance <= @weld
              }
            end

            def boundary_dp_point_plane_distance(point, triangle)
              normal = cross(
                subtract(triangle[1], triangle[0]),
                subtract(triangle[2], triangle[0])
              )
              magnitude = Math.sqrt(magnitude_squared(normal))
              return 0.0 if magnitude <= 1.0e-30

              dot(subtract(point, triangle[0]), normal).abs / magnitude
            end

            def boundary_dp_find_weld_cluster(point)
              clusters = Array(@boundary_dp_weld_clusters)
              clusters.min_by do |cluster|
                representative = cluster.fetch('representative_in')
                squared_distance(point, representative)
              end&.then do |cluster|
                representative = cluster.fetch('representative_in')
                distance = Math.sqrt(squared_distance(point, representative))
                next nil if distance > @weld

                cluster.merge(
                  'query_distance_to_representative_in' => distance.round(15),
                  'query_distance_to_representative_mm' =>
                    (distance * 25.4).round(12)
                )
              end
            end

            def boundary_dp_triangle_area(triangle)
              Math.sqrt(
                magnitude_squared(
                  cross(
                    subtract(triangle[1], triangle[0]),
                    subtract(triangle[2], triangle[0])
                  )
                )
              ) * 0.5
            end

            def boundary_dp_round_point(point)
              point.map { |value| value.to_f.round(15) }
            end

            def boundary_dp_point_mm(point)
              point.map { |value| (value.to_f * 25.4).round(12) }
            end
          end
        end
      end
    end
  end
end
