# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_boundary_ear_repair'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            unless private_method_defined?(:boundary_ear_conforming_triangle_soup_without_dp)
              alias_method :boundary_ear_conforming_triangle_soup_without_dp,
                           :boundary_ear_conforming_triangle_soup
            end

            private

            # Keep the conservative boundary-only repair policy, but replace the
            # greedy ear choice with a complete dynamic-programming search.
            # Collinear runs are common because all inserted points lie on the
            # three source-triangle edges. A locally valid greedy ear can leave a
            # final collinear triple; DP selects a triangulation that preserves
            # every boundary segment without generating an interior centroid.
            def boundary_ear_conforming_triangle_soup(triangles)
              @boundary_dp_last_failure = nil
              repaired, detail =
                boundary_ear_conforming_triangle_soup_without_dp(triangles)
              detail = (detail || {}).merge(
                'boundary_builder_mode' =>
                  'single_edge_assignment_with_explicit_corners',
                'triangulation_mode' =>
                  'boundary_vertex_dynamic_programming'
              )
              detail['boundary_dp_failure'] = @boundary_dp_last_failure if
                @boundary_dp_last_failure
              [repaired, detail]
            end

            def boundary_ear_subdivide_triangle(triangle, candidate_vertices)
              return [] if degenerate_triangle?(triangle)

              boundary, assignment_report =
                boundary_dp_build_boundary(triangle, candidate_vertices)
              if boundary.length < 3
                @boundary_dp_last_failure = assignment_report.merge(
                  'stage' => 'boundary_build',
                  'reason' => 'boundary_has_fewer_than_three_vertices'
                )
                return nil
              end
              return [triangle] if boundary.length == 3

              reference_normal = cross(
                subtract(triangle[1], triangle[0]),
                subtract(triangle[2], triangle[0])
              )
              if magnitude_squared(reference_normal) <= 1.0e-30
                @boundary_dp_last_failure = assignment_report.merge(
                  'stage' => 'reference_normal',
                  'reason' => 'source_triangle_degenerate'
                )
                return nil
              end

              index_triangles, dp_report = boundary_dp_triangulate_indices(
                boundary,
                reference_normal
              )
              unless index_triangles
                @boundary_dp_last_failure = assignment_report.merge(
                  dp_report,
                  'stage' => 'dynamic_programming'
                )
                return nil
              end

              unless boundary_ear_local_topology_valid?(
                boundary.length,
                index_triangles
              )
                @boundary_dp_last_failure = assignment_report.merge(
                  dp_report,
                  'stage' => 'local_topology',
                  'reason' => 'boundary_or_diagonal_occurrence_invalid'
                )
                return nil
              end

              output = index_triangles.filter_map do |indices|
                candidate = indices.map { |index| boundary.fetch(index) }
                next if degenerate_triangle?(candidate)

                normal = cross(
                  subtract(candidate[1], candidate[0]),
                  subtract(candidate[2], candidate[0])
                )
                dot(normal, reference_normal).negative? ?
                  [candidate[0], candidate[2], candidate[1]] : candidate
              end
              if output.length != index_triangles.length
                @boundary_dp_last_failure = assignment_report.merge(
                  dp_report,
                  'stage' => 'output_build',
                  'reason' => 'selected_triangle_became_degenerate',
                  'selected_triangle_count' => index_triangles.length,
                  'output_triangle_count' => output.length
                )
                return nil
              end

              unless boundary_ear_area_preserved?(triangle, output)
                @boundary_dp_last_failure = assignment_report.merge(
                  dp_report,
                  'stage' => 'area_check',
                  'reason' => 'triangle_area_not_preserved'
                )
                return nil
              end

              output
            rescue StandardError => e
              @boundary_dp_last_failure = {
                'stage' => 'exception',
                'reason' => "#{e.class}: #{e.message}"
              }
              nil
            end

            # Assign each welded representative to at most one source edge.
            # Source corners are inserted explicitly, so a point close to a
            # corner cannot appear again on both adjacent edges.
            def boundary_dp_build_boundary(triangle, candidate_vertices)
              corner_tolerance_squared = @weld * @weld
              edge_rows = Array.new(3) { [] }
              assigned_count = 0
              multi_edge_candidate_count = 0

              candidate_vertices.each do |point|
                next if triangle.any? do |corner|
                  squared_distance(point, corner) <= corner_tolerance_squared
                end

                matches = 3.times.filter_map do |edge_index|
                  a = triangle.fetch(edge_index)
                  b = triangle.fetch((edge_index + 1) % 3)
                  match = boundary_dp_point_edge_match(point, a, b)
                  [edge_index, *match] if match
                end
                next if matches.empty?

                multi_edge_candidate_count += 1 if matches.length > 1
                edge_index, parameter, distance_squared = matches.min_by do |row|
                  [row[2], (row[1] - 0.5).abs, row[0]]
                end
                edge_rows.fetch(edge_index) << [parameter, point, distance_squared]
                assigned_count += 1
              end

              boundary = []
              edge_rows.each_with_index do |rows, edge_index|
                boundary << triangle.fetch(edge_index)
                rows.sort_by! do |parameter, point, distance_squared|
                  [parameter, distance_squared, *point]
                end
                rows.each do |_parameter, point, _distance_squared|
                  next if squared_distance(boundary[-1], point) <=
                          corner_tolerance_squared

                  boundary << point
                end
              end
              boundary = boundary_dp_remove_repeated_vertices(boundary)

              [
                boundary,
                {
                  'candidate_vertex_count' => candidate_vertices.length,
                  'assigned_interior_vertex_count' => assigned_count,
                  'multi_edge_candidate_count' => multi_edge_candidate_count,
                  'edge_interior_vertex_counts' => edge_rows.map(&:length),
                  'boundary_vertex_count' => boundary.length
                }
              ]
            end

            def boundary_dp_point_edge_match(point, a, b)
              ab = subtract(b, a)
              length_squared = magnitude_squared(ab)
              return nil if length_squared <= 1.0e-30

              ap = subtract(point, a)
              parameter = dot(ap, ab) / length_squared
              return nil unless parameter.positive? && parameter < 1.0

              projected = 3.times.map do |axis|
                a[axis].to_f + ab[axis] * parameter
              end
              distance_squared = squared_distance(point, projected)
              return nil if distance_squared > @weld * @weld

              [parameter, distance_squared]
            end

            def boundary_dp_remove_repeated_vertices(boundary)
              result = []
              boundary.each do |point|
                next if result.any? do |existing|
                  squared_distance(existing, point) <= @weld * @weld
                end

                result << point
              end
              result
            end

            def boundary_dp_triangulate_indices(boundary, reference_normal)
              count = boundary.length
              memo = {}
              choices = {}
              tested_split_count = 0
              valid_split_count = 0

              solve = lambda do |left, right|
                key = [left, right]
                return memo[key] if memo.key?(key)
                return memo[key] = true if right <= left + 1

                memo[key] = false
                ((left + 1)...right).each do |middle|
                  tested_split_count += 1
                  next unless solve.call(left, middle)
                  next unless solve.call(middle, right)
                  next unless boundary_dp_triangle_valid?(
                    boundary, left, middle, right, reference_normal
                  )

                  valid_split_count += 1
                  choices[key] = middle
                  memo[key] = true
                  break
                end
                memo[key]
              end

              unless solve.call(0, count - 1)
                return [
                  nil,
                  {
                    'reason' => 'no_complete_non_degenerate_triangulation',
                    'boundary_vertex_count' => count,
                    'tested_split_count' => tested_split_count,
                    'valid_split_count' => valid_split_count,
                    'memo_state_count' => memo.length
                  }
                ]
              end

              triangles = []
              emit = lambda do |left, right|
                return if right <= left + 1

                middle = choices.fetch([left, right])
                emit.call(left, middle)
                emit.call(middle, right)
                triangles << [left, middle, right]
              end
              emit.call(0, count - 1)

              [
                triangles,
                {
                  'reason' => 'triangulated',
                  'boundary_vertex_count' => count,
                  'selected_triangle_count' => triangles.length,
                  'tested_split_count' => tested_split_count,
                  'valid_split_count' => valid_split_count,
                  'memo_state_count' => memo.length
                }
              ]
            end

            def boundary_dp_triangle_valid?(
              boundary, left, middle, right, reference_normal
            )
              candidate = [
                boundary.fetch(left),
                boundary.fetch(middle),
                boundary.fetch(right)
              ]
              return false if degenerate_triangle?(candidate)

              normal = cross(
                subtract(candidate[1], candidate[0]),
                subtract(candidate[2], candidate[0])
              )
              dot(normal, reference_normal).positive?
            end
          end
        end
      end
    end
  end
end
