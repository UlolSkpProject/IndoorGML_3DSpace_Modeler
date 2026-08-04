# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_boundary_dp_edge_projection_repair'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            unless private_method_defined?(:boundary_dp_conforming_triangle_soup_without_global_edge_support)
              alias_method :boundary_dp_conforming_triangle_soup_without_global_edge_support,
                           :boundary_ear_conforming_triangle_soup
              alias_method :boundary_dp_subdivide_triangle_without_global_edge_support,
                           :boundary_ear_subdivide_triangle
            end

            private

            # Dev-only candidate repair.
            #
            # Candidate vertices are currently matched to source-triangle edges
            # independently per triangle. A vertex that lies exactly on one real
            # mesh edge can therefore also be inserted into an unrelated nearby
            # edge when the latter is merely within the weld tolerance. This
            # creates a false T-junction and 1/3-use edge fans after final welding.
            #
            # Build one support plan for the complete welded triangle soup:
            # - exact edge supports take precedence over positive-distance hits;
            # - when no exact support exists, all projected hits must agree on one
            #   projection location within a very small numerical threshold;
            # - incompatible support locations are treated as ambiguous and are
            #   not inserted, leaving the existing hard gates to reject/fallback.
            def boundary_ear_conforming_triangle_soup(triangles)
              begin
                plan, report = boundary_dp_global_edge_support_plan(triangles)
              rescue StandardError => e
                return [
                  nil,
                  {
                    'candidate_support_mode' =>
                      'global_support_plan_exception_original_fallback',
                    'global_edge_support_error' =>
                      "#{e.class}: #{e.message}"
                  }
                ]
              end

              @boundary_dp_global_edge_support_plan = plan
              @boundary_dp_global_edge_support_report = report
              @boundary_dp_global_edge_support_triangle_cursor = -1

              repaired, detail =
                boundary_dp_conforming_triangle_soup_without_global_edge_support(
                  triangles
                )
              detail = (detail || {}).merge(
                'candidate_support_mode' =>
                  'global_exact_support_precedence_then_single_projection_group',
                'global_edge_support' => report
              )
              [repaired, detail]
            ensure
              @boundary_dp_global_edge_support_plan = nil
              @boundary_dp_global_edge_support_report = nil
              @boundary_dp_global_edge_support_triangle_cursor = nil
              @boundary_dp_global_edge_support_current_triangle = nil
            end

            def boundary_ear_subdivide_triangle(triangle, candidate_vertices)
              @boundary_dp_global_edge_support_triangle_cursor =
                @boundary_dp_global_edge_support_triangle_cursor.to_i + 1
              @boundary_dp_global_edge_support_current_triangle =
                @boundary_dp_global_edge_support_triangle_cursor
              boundary_dp_subdivide_triangle_without_global_edge_support(
                triangle,
                candidate_vertices
              )
            ensure
              @boundary_dp_global_edge_support_current_triangle = nil
            end

            def boundary_dp_build_boundary(triangle, candidate_vertices)
              triangle_index = @boundary_dp_global_edge_support_current_triangle
              plan = @boundary_dp_global_edge_support_plan || {}
              corner_tolerance_squared = @weld * @weld
              edge_rows = Array.new(3) { [] }
              assigned_count = 0
              projected_count = 0
              projection_distances = []
              rejected_candidate_count = 0

              candidate_vertices.each_with_index do |point, candidate_index|
                if triangle.any? do |corner|
                     squared_distance(point, corner) <= corner_tolerance_squared
                   end
                  next
                end

                selected = plan[[triangle_index, candidate_index]]
                unless selected
                  rejected_candidate_count += 1
                  next
                end

                edge_index = selected.fetch(:edge_index)
                parameter = selected.fetch(:parameter)
                distance_squared = selected.fetch(:distance_squared)
                projected = selected.fetch(:projected)
                boundary_point = if selected[:exact_support]
                                   point
                                 else
                                   projected
                                 end

                edge_rows.fetch(edge_index) << [
                  parameter,
                  boundary_point,
                  distance_squared,
                  point,
                  candidate_index
                ]
                assigned_count += 1
                if distance_squared.positive?
                  projected_count += 1
                  projection_distances << Math.sqrt(distance_squared)
                end
              end

              boundary = []
              edge_rows.each_with_index do |rows, edge_index|
                boundary << triangle.fetch(edge_index)
                rows.sort_by! do |parameter, boundary_point, distance_squared,
                                  original, candidate_index|
                  [
                    parameter,
                    distance_squared,
                    candidate_index,
                    *boundary_point,
                    *original
                  ]
                end
                rows.each do |_parameter, boundary_point, _distance_squared,
                              _original, _candidate_index|
                  next if squared_distance(boundary[-1], boundary_point) <=
                          corner_tolerance_squared

                  boundary << boundary_point
                end
              end
              boundary = boundary_dp_remove_repeated_vertices(boundary)

              max_projection = projection_distances.max.to_f
              [
                boundary,
                {
                  'candidate_vertex_count' => candidate_vertices.length,
                  'assigned_interior_vertex_count' => assigned_count,
                  'multi_edge_candidate_count' => 0,
                  'edge_interior_vertex_counts' => edge_rows.map(&:length),
                  'boundary_vertex_count' => boundary.length,
                  'boundary_vertex_coordinate_mode' =>
                    'global_support_original_or_edge_projection',
                  'candidate_support_mode' =>
                    'global_exact_support_precedence_then_single_projection_group',
                  'projected_interior_vertex_count' => projected_count,
                  'rejected_candidate_count' => rejected_candidate_count,
                  'max_projection_distance_in' => max_projection.round(15),
                  'max_projection_distance_mm' =>
                    (max_projection * 25.4).round(12)
                }
              ]
            end

            def boundary_dp_global_edge_support_plan(triangles)
              flattened = triangles.flatten(1)
              welding = weld_endpoints(flattened)
              point_cluster = welding.fetch(:point_cluster)
              representatives = welding.fetch(:clusters).map do |cluster|
                cluster.fetch(:representative).map(&:to_f)
              end
              welded_triangles = triangles.each_index.map do |triangle_index|
                offset = triangle_index * 3
                3.times.map do |corner|
                  representatives.fetch(
                    point_cluster.fetch(offset + corner)
                  )
                end
              end

              exact_distance = [@weld * 1.0e-4, 1.0e-12].max
              exact_distance_squared = exact_distance * exact_distance
              corner_tolerance_squared = @weld * @weld
              matches_by_candidate = Hash.new { |hash, key| hash[key] = [] }

              representatives.each_with_index do |point, candidate_index|
                welded_triangles.each_with_index do |triangle, triangle_index|
                  next if triangle.any? do |corner|
                    squared_distance(point, corner) <= corner_tolerance_squared
                  end

                  3.times do |edge_index|
                    match = boundary_dp_global_edge_match(
                      point,
                      triangle.fetch(edge_index),
                      triangle.fetch((edge_index + 1) % 3)
                    )
                    next unless match

                    matches_by_candidate[candidate_index] << {
                      candidate_index: candidate_index,
                      triangle_index: triangle_index,
                      edge_index: edge_index,
                      parameter: match.fetch(:parameter),
                      distance_squared: match.fetch(:distance_squared),
                      projected: match.fetch(:projected),
                      exact_support:
                        match.fetch(:distance_squared) <= exact_distance_squared
                    }
                  end
                end
              end

              plan = {}
              candidate_reports = []
              ambiguous_count = 0
              exact_candidate_count = 0
              projected_candidate_count = 0
              selected_match_count = 0
              rejected_match_count = 0

              matches_by_candidate.keys.sort.each do |candidate_index|
                matches = matches_by_candidate.fetch(candidate_index)
                exact_matches = matches.select { |row| row[:exact_support] }
                selected = []
                selection_mode = nil
                projection_group_count = 0

                if exact_matches.any?
                  selection_mode = 'exact_support_only'
                  exact_candidate_count += 1
                  selected = boundary_dp_one_match_per_triangle(exact_matches)
                  projection_group_count = boundary_dp_projection_groups(
                    exact_matches,
                    exact_distance_squared
                  ).length
                else
                  groups = boundary_dp_projection_groups(
                    matches,
                    exact_distance_squared
                  )
                  projection_group_count = groups.length
                  if groups.length == 1
                    selection_mode = 'single_compatible_projection_group'
                    projected_candidate_count += 1
                    selected = boundary_dp_one_match_per_triangle(
                      groups.first.fetch(:rows)
                    )
                  else
                    selection_mode = 'ambiguous_projection_groups'
                    ambiguous_count += 1
                  end
                end

                selected.each do |row|
                  plan[[row.fetch(:triangle_index), candidate_index]] = row
                end
                selected_match_count += selected.length
                rejected_match_count += matches.length - selected.length

                candidate_reports << {
                  'candidate_cluster_index' => candidate_index,
                  'candidate_point_in' => representatives.fetch(candidate_index).map do |value|
                    value.to_f.round(15)
                  end,
                  'candidate_point_mm' => representatives.fetch(candidate_index).map do |value|
                    (value.to_f * 25.4).round(12)
                  end,
                  'all_match_count' => matches.length,
                  'exact_match_count' => exact_matches.length,
                  'projection_group_count' => projection_group_count,
                  'selection_mode' => selection_mode,
                  'selected_match_count' => selected.length,
                  'rejected_near_edge_match_count' =>
                    matches.length - selected.length,
                  'selected_supports' => selected.map do |row|
                    boundary_dp_support_row_report(row)
                  end
                }
              end

              report = {
                'candidate_cluster_count' => representatives.length,
                'matched_candidate_count' => matches_by_candidate.length,
                'exact_support_candidate_count' => exact_candidate_count,
                'projected_support_candidate_count' => projected_candidate_count,
                'ambiguous_candidate_count' => ambiguous_count,
                'selected_support_match_count' => selected_match_count,
                'rejected_near_edge_match_count' => rejected_match_count,
                'exact_support_distance_in' => exact_distance.round(15),
                'exact_support_distance_mm' =>
                  (exact_distance * 25.4).round(12),
                'candidate_supports' => candidate_reports
              }
              [plan, report]
            end

            def boundary_dp_global_edge_match(point, a, b)
              ab = subtract(b, a)
              length_squared = magnitude_squared(ab)
              return nil if length_squared <= 1.0e-30

              parameter = dot(subtract(point, a), ab) / length_squared
              return nil unless parameter.positive? && parameter < 1.0

              projected = 3.times.map do |axis|
                a[axis].to_f + ab[axis] * parameter
              end
              distance_squared = squared_distance(point, projected)
              return nil if distance_squared > @weld * @weld

              {
                parameter: parameter,
                distance_squared: distance_squared,
                projected: projected
              }
            end

            def boundary_dp_projection_groups(rows, tolerance_squared)
              groups = []
              rows.sort_by do |row|
                [
                  row.fetch(:distance_squared),
                  row.fetch(:triangle_index),
                  row.fetch(:edge_index)
                ]
              end.each do |row|
                group = groups.find do |candidate|
                  squared_distance(
                    row.fetch(:projected),
                    candidate.fetch(:representative)
                  ) <= tolerance_squared
                end
                if group
                  group.fetch(:rows) << row
                else
                  groups << {
                    representative: row.fetch(:projected),
                    rows: [row]
                  }
                end
              end
              groups
            end

            def boundary_dp_one_match_per_triangle(rows)
              rows.group_by { |row| row.fetch(:triangle_index) }
                  .keys.sort.map do |triangle_index|
                rows_for_triangle = rows.select do |row|
                  row.fetch(:triangle_index) == triangle_index
                end
                rows_for_triangle.min_by do |row|
                  [
                    row.fetch(:distance_squared),
                    (row.fetch(:parameter) - 0.5).abs,
                    row.fetch(:edge_index)
                  ]
                end
              end
            end

            def boundary_dp_support_row_report(row)
              {
                'triangle_index' => row.fetch(:triangle_index),
                'edge_index' => row.fetch(:edge_index),
                'parameter' => row.fetch(:parameter).round(15),
                'distance_in' =>
                  Math.sqrt(row.fetch(:distance_squared)).round(15),
                'distance_mm' => (
                  Math.sqrt(row.fetch(:distance_squared)) * 25.4
                ).round(12),
                'exact_support' => row.fetch(:exact_support),
                'projected_point_in' => row.fetch(:projected).map do |value|
                  value.to_f.round(15)
                end,
                'projected_point_mm' => row.fetch(:projected).map do |value|
                  (value.to_f * 25.4).round(12)
                end
              }
            end
          end
        end
      end
    end
  end
end
