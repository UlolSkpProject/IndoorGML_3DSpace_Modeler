# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_boundary_dp_edge_projection_repair'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            unless private_method_defined?(:boundary_dp_conforming_triangle_soup_without_edge_fan_diagnostic)
              alias_method :boundary_dp_conforming_triangle_soup_without_edge_fan_diagnostic,
                           :boundary_ear_conforming_triangle_soup
              alias_method :boundary_dp_subdivide_triangle_without_edge_fan_diagnostic,
                           :boundary_ear_subdivide_triangle
              alias_method :boundary_dp_build_boundary_without_edge_fan_diagnostic,
                           :boundary_dp_build_boundary
            end

            private

            # Dev-only instrumentation for a repaired soup that still fails the
            # final closed-two-manifold hard gate. No geometry or decision is
            # changed. The diagnostic records every edge whose final occurrence
            # count is not two, its incident output triangles, source-triangle
            # provenance, and the candidate projections that can explain it.
            def boundary_ear_conforming_triangle_soup(triangles)
              @boundary_dp_edge_fan_source_index = -1
              @boundary_dp_edge_fan_output_index = 0
              @boundary_dp_edge_fan_provenance = []
              @boundary_dp_edge_fan_projection_rows = []
              @boundary_dp_edge_fan_boundary_rows = []
              @boundary_dp_edge_fan_candidate_vertices = nil

              repaired, detail =
                boundary_dp_conforming_triangle_soup_without_edge_fan_diagnostic(
                  triangles
                )
              detail = detail || {}

              if repaired
                begin
                  diagnostic = boundary_dp_build_repaired_edge_fan_diagnostic(
                    repaired
                  )
                  detail = detail.merge(
                    'repaired_edge_fan_diagnostic' => diagnostic
                  )
                rescue StandardError => e
                  detail = detail.merge(
                    'repaired_edge_fan_diagnostic_error' =>
                      "#{e.class}: #{e.message}"
                  )
                end
              end

              [repaired, detail]
            ensure
              @boundary_dp_edge_fan_source_index = nil
              @boundary_dp_edge_fan_output_index = nil
              @boundary_dp_edge_fan_provenance = nil
              @boundary_dp_edge_fan_projection_rows = nil
              @boundary_dp_edge_fan_boundary_rows = nil
              @boundary_dp_edge_fan_candidate_vertices = nil
            end

            def boundary_ear_subdivide_triangle(triangle, candidate_vertices)
              @boundary_dp_edge_fan_source_index =
                @boundary_dp_edge_fan_source_index.to_i + 1
              source_index = @boundary_dp_edge_fan_source_index

              result =
                boundary_dp_subdivide_triangle_without_edge_fan_diagnostic(
                  triangle,
                  candidate_vertices
                )
              return result unless result

              begin
                subdivided = !(
                  result.length == 1 &&
                  boundary_ear_same_triangle?(result.first, triangle)
                )
                result.each_with_index do |output_triangle, local_index|
                  @boundary_dp_edge_fan_provenance << {
                    'output_triangle_index' =>
                      @boundary_dp_edge_fan_output_index,
                    'source_triangle_index' => source_index,
                    'local_output_index' => local_index,
                    'source_triangle_subdivided' => subdivided,
                    'source_triangle_points_in' =>
                      boundary_dp_edge_fan_round_triangle(triangle),
                    'source_triangle_points_mm' =>
                      boundary_dp_edge_fan_triangle_mm(triangle),
                    'output_triangle_points_in' =>
                      boundary_dp_edge_fan_round_triangle(output_triangle),
                    'output_triangle_points_mm' =>
                      boundary_dp_edge_fan_triangle_mm(output_triangle)
                  }
                  @boundary_dp_edge_fan_output_index += 1
                end
              rescue StandardError => e
                @boundary_dp_edge_fan_provenance << {
                  'source_triangle_index' => source_index,
                  'diagnostic_error' => "#{e.class}: #{e.message}"
                }
              end

              result
            end

            def boundary_dp_build_boundary(triangle, candidate_vertices)
              boundary, report =
                boundary_dp_build_boundary_without_edge_fan_diagnostic(
                  triangle,
                  candidate_vertices
                )

              begin
                @boundary_dp_edge_fan_candidate_vertices ||= candidate_vertices
                source_index = @boundary_dp_edge_fan_source_index
                projection_rows = boundary_dp_edge_fan_projection_rows_for(
                  triangle,
                  candidate_vertices,
                  source_index
                )
                @boundary_dp_edge_fan_projection_rows.concat(projection_rows)
                @boundary_dp_edge_fan_boundary_rows << {
                  'source_triangle_index' => source_index,
                  'boundary_points_in' => boundary.map do |point|
                    boundary_dp_edge_fan_round_point(point)
                  end,
                  'boundary_points_mm' => boundary.map do |point|
                    boundary_dp_edge_fan_point_mm(point)
                  end,
                  'boundary_report' => report
                }
              rescue StandardError => e
                @boundary_dp_edge_fan_boundary_rows << {
                  'source_triangle_index' =>
                    @boundary_dp_edge_fan_source_index,
                  'diagnostic_error' => "#{e.class}: #{e.message}"
                }
              end

              [boundary, report]
            end

            def boundary_dp_edge_fan_projection_rows_for(
              triangle,
              candidate_vertices,
              source_index
            )
              corner_tolerance_squared = @weld * @weld
              candidate_vertices.each_with_index.filter_map do |point, cluster_index|
                next if triangle.any? do |corner|
                  squared_distance(point, corner) <= corner_tolerance_squared
                end

                matches = 3.times.filter_map do |edge_index|
                  a = triangle.fetch(edge_index)
                  b = triangle.fetch((edge_index + 1) % 3)
                  match = boundary_dp_projected_edge_match(point, a, b)
                  [edge_index, *match] if match
                end
                next if matches.empty?

                selected = matches.min_by do |row|
                  [row[2], (row[1] - 0.5).abs, row[0]]
                end
                edge_index, parameter, distance_squared, projected = selected
                {
                  'source_triangle_index' => source_index,
                  'candidate_cluster_index' => cluster_index,
                  'candidate_point_in' =>
                    boundary_dp_edge_fan_round_point(point),
                  'candidate_point_mm' =>
                    boundary_dp_edge_fan_point_mm(point),
                  'matched_edge_count' => matches.length,
                  'selected_edge_index' => edge_index,
                  'selected_edge_parameter' => parameter.round(15),
                  'projection_distance_in' =>
                    Math.sqrt(distance_squared).round(15),
                  'projection_distance_mm' =>
                    (Math.sqrt(distance_squared) * 25.4).round(12),
                  'projected_point_in' =>
                    boundary_dp_edge_fan_round_point(projected),
                  'projected_point_mm' =>
                    boundary_dp_edge_fan_point_mm(projected),
                  'source_edge_points_in' => [
                    triangle.fetch(edge_index),
                    triangle.fetch((edge_index + 1) % 3)
                  ].map { |value| boundary_dp_edge_fan_round_point(value) },
                  'source_edge_points_mm' => [
                    triangle.fetch(edge_index),
                    triangle.fetch((edge_index + 1) % 3)
                  ].map { |value| boundary_dp_edge_fan_point_mm(value) },
                  'all_matches' => matches.map do |match|
                    match_edge, match_parameter, match_distance_squared,
                      match_projected = match
                    {
                      'edge_index' => match_edge,
                      'parameter' => match_parameter.round(15),
                      'distance_in' =>
                        Math.sqrt(match_distance_squared).round(15),
                      'distance_mm' =>
                        (Math.sqrt(match_distance_squared) * 25.4).round(12),
                      'projected_point_in' =>
                        boundary_dp_edge_fan_round_point(match_projected),
                      'projected_point_mm' =>
                        boundary_dp_edge_fan_point_mm(match_projected)
                    }
                  end
                }
              end
            end

            def boundary_dp_build_repaired_edge_fan_diagnostic(triangles)
              flattened = triangles.flatten(1)
              welding = weld_endpoints(flattened)
              point_cluster = welding.fetch(:point_cluster)
              clusters = welding.fetch(:clusters)
              edge_incidents = Hash.new { |hash, key| hash[key] = [] }

              triangles.each_with_index do |triangle, triangle_index|
                offset = triangle_index * 3
                cluster_vertices = 3.times.map do |corner|
                  point_cluster.fetch(offset + corner)
                end
                3.times do |edge_index|
                  from = cluster_vertices.fetch(edge_index)
                  to = cluster_vertices.fetch((edge_index + 1) % 3)
                  key = [from, to].sort
                  edge_incidents[key] << {
                    'output_triangle_index' => triangle_index,
                    'directed_from_cluster' => from,
                    'directed_to_cluster' => to,
                    'triangle_edge_index' => edge_index
                  }
                end
              end

              histogram = edge_incidents.values.map(&:length).tally
              problem_edges = edge_incidents.filter_map do |edge, incidents|
                next if incidents.length == 2

                boundary_dp_edge_fan_problem_edge(
                  edge,
                  incidents,
                  clusters
                )
              end

              {
                'mode' =>
                  'repaired_soup_edge_occurrence_with_source_provenance',
                'triangle_count' => triangles.length,
                'welded_vertex_count' => clusters.length,
                'unique_edge_count' => edge_incidents.length,
                'edge_occurrence_histogram' =>
                  histogram.transform_keys(&:to_s).sort.to_h,
                'problem_edge_count' => problem_edges.length,
                'boundary_edge_count' =>
                  problem_edges.count { |row| row['occurrence_count'] == 1 },
                'non_manifold_edge_count' =>
                  problem_edges.count { |row| row['occurrence_count'] > 2 },
                'problem_edges_share_candidate_cluster' =>
                  boundary_dp_edge_fan_shared_candidate_clusters(problem_edges),
                'problem_edges' => problem_edges,
                'projection_row_count' =>
                  Array(@boundary_dp_edge_fan_projection_rows).length,
                'boundary_build_row_count' =>
                  Array(@boundary_dp_edge_fan_boundary_rows).length
              }
            end

            def boundary_dp_edge_fan_problem_edge(edge, incidents, clusters)
              endpoint_rows = edge.map do |cluster_index|
                cluster = clusters.fetch(cluster_index)
                point = cluster.fetch(:representative).map(&:to_f)
                {
                  'repaired_cluster_index' => cluster_index,
                  'point_in' => boundary_dp_edge_fan_round_point(point),
                  'point_mm' => boundary_dp_edge_fan_point_mm(point),
                  'member_count' => cluster.fetch(:members).length,
                  'cluster_diameter_mm' => (
                    Math.sqrt(cluster.fetch(:diameter_squared).to_f) * 25.4
                  ).round(12),
                  'candidate_cluster_matches' =>
                    boundary_dp_edge_fan_candidate_matches(point)
                }
              end
              endpoint_points = endpoint_rows.map { |row| row.fetch('point_in') }
              relevant_projections =
                boundary_dp_edge_fan_relevant_projections(endpoint_points)

              {
                'occurrence_count' => incidents.length,
                'edge_length_in' => Math.sqrt(
                  squared_distance(endpoint_points[0], endpoint_points[1])
                ).round(15),
                'edge_length_mm' => (
                  Math.sqrt(
                    squared_distance(endpoint_points[0], endpoint_points[1])
                  ) * 25.4
                ).round(12),
                'endpoints' => endpoint_rows,
                'candidate_cluster_indices' => endpoint_rows.flat_map do |row|
                  row.fetch('candidate_cluster_matches').map do |match|
                    match.fetch('candidate_cluster_index')
                  end
                end.uniq.sort,
                'incident_triangles' => incidents.map do |incident|
                  provenance = Array(@boundary_dp_edge_fan_provenance).find do |row|
                    row['output_triangle_index'] ==
                      incident['output_triangle_index']
                  end
                  incident.merge('provenance' => provenance)
                end,
                'related_projection_rows' => relevant_projections
              }
            end

            def boundary_dp_edge_fan_candidate_matches(point)
              Array(@boundary_dp_edge_fan_candidate_vertices).each_with_index.filter_map do |candidate, index|
                distance = Math.sqrt(squared_distance(point, candidate))
                next if distance > @weld

                {
                  'candidate_cluster_index' => index,
                  'distance_in' => distance.round(15),
                  'distance_mm' => (distance * 25.4).round(12),
                  'candidate_point_in' =>
                    boundary_dp_edge_fan_round_point(candidate),
                  'candidate_point_mm' =>
                    boundary_dp_edge_fan_point_mm(candidate)
                }
              end.sort_by do |row|
                [row['distance_in'], row['candidate_cluster_index']]
              end
            end

            def boundary_dp_edge_fan_relevant_projections(endpoint_points)
              Array(@boundary_dp_edge_fan_projection_rows).select do |row|
                [row['candidate_point_in'], row['projected_point_in']].any? do |point|
                  endpoint_points.any? do |endpoint|
                    squared_distance(point, endpoint) <= @weld * @weld
                  end
                end
              end
            end

            def boundary_dp_edge_fan_shared_candidate_clusters(problem_edges)
              counts = Hash.new(0)
              problem_edges.each do |edge|
                edge.fetch('candidate_cluster_indices').each do |cluster_index|
                  counts[cluster_index] += 1
                end
              end
              counts.select { |_cluster_index, count| count > 1 }
                    .sort
                    .to_h
                    .transform_keys(&:to_s)
            end

            def boundary_dp_edge_fan_round_triangle(triangle)
              triangle.map { |point| boundary_dp_edge_fan_round_point(point) }
            end

            def boundary_dp_edge_fan_triangle_mm(triangle)
              triangle.map { |point| boundary_dp_edge_fan_point_mm(point) }
            end

            def boundary_dp_edge_fan_round_point(point)
              point.map { |value| value.to_f.round(15) }
            end

            def boundary_dp_edge_fan_point_mm(point)
              point.map { |value| (value.to_f * 25.4).round(12) }
            end
          end
        end
      end
    end
  end
end
