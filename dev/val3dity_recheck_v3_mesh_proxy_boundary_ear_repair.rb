# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_interior_loop_cap'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            unless private_method_defined?(:conforming_triangle_soup_without_boundary_ear_repair)
              alias_method :conforming_triangle_soup_without_boundary_ear_repair,
                           :conforming_triangle_soup
              alias_method :triangle_soup_topology_without_boundary_ear_repair_report,
                           :triangle_soup_topology
            end

            private

            # Conservative dev-only repair for a failed conforming soup.
            #
            # The existing conformer inserts one centroid per subdivided triangle.
            # On very thin adjacent triangles, final tolerance welding can merge
            # those generated interior points and create exact duplicate slivers
            # plus 4-use edge fans. This alternative keeps the same welded
            # boundary segmentation but triangulates the convex boundary by ears,
            # adding no interior vertices.
            #
            # Existing successful soups are returned unchanged. The alternative
            # is selected only when the unchanged topology hard gate reports a
            # closed two-manifold result.
            def conforming_triangle_soup(triangles)
              original =
                conforming_triangle_soup_without_boundary_ear_repair(triangles)
              original_topology =
                triangle_soup_topology_without_boundary_ear_repair_report(
                  original
                )

              @boundary_ear_repair_report = {
                'boundary_ear_repair_attempted' => false,
                'boundary_ear_repair_applied' => false,
                'boundary_ear_repair_outcome' => 'not_candidate',
                'boundary_ear_repair_original_topology' => original_topology
              }

              return original if original_topology['closed_two_manifold'] == true
              return original unless boundary_ear_repair_candidate?(
                original_topology
              )

              @boundary_ear_repair_report[
                'boundary_ear_repair_attempted'
              ] = true

              repaired, detail = boundary_ear_conforming_triangle_soup(
                triangles
              )
              unless repaired
                @boundary_ear_repair_report.merge!(
                  'boundary_ear_repair_outcome' => 'triangulation_failed',
                  'boundary_ear_repair_detail' => detail
                )
                return original
              end

              repaired_topology =
                triangle_soup_topology_without_boundary_ear_repair_report(
                  repaired
                )
              @boundary_ear_repair_report.merge!(
                'boundary_ear_repair_repaired_topology' => repaired_topology,
                'boundary_ear_repair_original_triangle_count' =>
                  original.length,
                'boundary_ear_repair_repaired_triangle_count' =>
                  repaired.length,
                'boundary_ear_repair_detail' => detail
              )

              unless repaired_topology['closed_two_manifold'] == true
                @boundary_ear_repair_report[
                  'boundary_ear_repair_outcome'
                ] = 'repaired_topology_open'
                return original
              end

              @boundary_ear_repair_report.merge!(
                'boundary_ear_repair_applied' => true,
                'boundary_ear_repair_outcome' => 'applied'
              )
              repaired
            rescue StandardError => e
              @boundary_ear_repair_report = {
                'boundary_ear_repair_attempted' => true,
                'boundary_ear_repair_applied' => false,
                'boundary_ear_repair_outcome' => 'exception',
                'boundary_ear_repair_error' =>
                  "#{e.class}: #{e.message}"
              }
              original || triangles
            end

            def triangle_soup_topology(triangles)
              report =
                triangle_soup_topology_without_boundary_ear_repair_report(
                  triangles
                )
              repair = @boundary_ear_repair_report
              return report unless repair

              selected_count = if repair['boundary_ear_repair_applied'] == true
                                 repair[
                                   'boundary_ear_repair_repaired_triangle_count'
                                 ]
                               else
                                 repair[
                                   'boundary_ear_repair_original_triangle_count'
                                 ] || report['triangle_count']
                               end
              return report unless report['triangle_count'].to_i ==
                                   selected_count.to_i

              report.merge(repair)
            end

            def boundary_ear_repair_candidate?(topology)
              topology['boundary_edge_count'].to_i.zero? &&
                topology['non_manifold_edge_count'].to_i.positive? &&
                topology['degenerate_triangle_count'].to_i.zero?
            end

            def boundary_ear_conforming_triangle_soup(triangles)
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

              output = []
              subdivided_count = 0
              unchanged_count = 0

              welded_triangles.each_with_index do |triangle, triangle_index|
                result = boundary_ear_subdivide_triangle(
                  triangle,
                  representatives
                )
                unless result
                  return [
                    nil,
                    {
                      'failed_triangle_index' => triangle_index,
                      'input_triangle_count' => triangles.length
                    }
                  ]
                end

                if result.length == 1 &&
                   boundary_ear_same_triangle?(result.first, triangle)
                  unchanged_count += 1
                else
                  subdivided_count += 1
                end
                output.concat(result)
              end

              [
                output,
                {
                  'mode' => 'boundary_vertex_preserving_ear_triangulation',
                  'input_triangle_count' => triangles.length,
                  'output_triangle_count' => output.length,
                  'welded_vertex_count' => representatives.length,
                  'subdivided_triangle_count' => subdivided_count,
                  'unchanged_triangle_count' => unchanged_count,
                  'generated_interior_vertex_count' => 0
                }
              ]
            end

            def boundary_ear_subdivide_triangle(triangle, candidate_vertices)
              return [] if degenerate_triangle?(triangle)

              boundary = []
              3.times do |edge_index|
                a = triangle[edge_index]
                b = triangle[(edge_index + 1) % 3]
                edge_points = candidate_vertices.filter_map do |point|
                  parameter = point_on_segment_parameter(point, a, b)
                  [parameter, point] if parameter
                end
                edge_points.sort_by! do |parameter, point|
                  [parameter, *point]
                end
                edge_points.each_with_index do |(_parameter, point), index|
                  next if edge_index.positive? && index.zero?
                  next if edge_index == 2 &&
                          index == edge_points.length - 1

                  boundary << point
                end
              end
              boundary = deduplicate_cycle_points(boundary)
              return [triangle] if boundary.length == 3
              return nil if boundary.length < 3

              reference_normal = cross(
                subtract(triangle[1], triangle[0]),
                subtract(triangle[2], triangle[0])
              )
              return nil if magnitude_squared(reference_normal) <= 1.0e-30

              index_triangles = boundary_ear_triangulate_indices(
                boundary,
                reference_normal
              )
              return nil unless index_triangles
              return nil unless boundary_ear_local_topology_valid?(
                boundary.length,
                index_triangles
              )

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
              return nil if output.empty?
              return nil unless boundary_ear_area_preserved?(
                triangle,
                output
              )

              output
            end

            def boundary_ear_triangulate_indices(boundary, reference_normal)
              indices = (0...boundary.length).to_a
              triangles = []
              guard = 0

              while indices.length > 3
                ear_position = nil
                indices.length.times do |position|
                  prev = indices[(position - 1) % indices.length]
                  curr = indices[position]
                  nxt = indices[(position + 1) % indices.length]
                  candidate = [
                    boundary.fetch(prev),
                    boundary.fetch(curr),
                    boundary.fetch(nxt)
                  ]
                  next if degenerate_triangle?(candidate)

                  normal = cross(
                    subtract(candidate[1], candidate[0]),
                    subtract(candidate[2], candidate[0])
                  )
                  next unless dot(normal, reference_normal).positive?

                  ear_position = position
                  triangles << [prev, curr, nxt]
                  break
                end
                return nil unless ear_position

                indices.delete_at(ear_position)
                guard += 1
                return nil if guard > boundary.length * boundary.length
              end

              if indices.length == 3
                candidate = indices.map { |index| boundary.fetch(index) }
                return nil if degenerate_triangle?(candidate)

                normal = cross(
                  subtract(candidate[1], candidate[0]),
                  subtract(candidate[2], candidate[0])
                )
                indices = [indices[0], indices[2], indices[1]] if
                  dot(normal, reference_normal).negative?
                triangles << indices
              end
              triangles
            end

            def boundary_ear_local_topology_valid?(vertex_count, triangles)
              edge_counts = Hash.new(0)
              triangles.each do |triangle|
                3.times do |index|
                  edge = [
                    triangle[index],
                    triangle[(index + 1) % 3]
                  ].sort
                  edge_counts[edge] += 1
                end
              end

              boundary_edges = vertex_count.times.map do |index|
                [index, (index + 1) % vertex_count].sort
              end
              boundary_edges.all? { |edge| edge_counts[edge] == 1 } &&
                edge_counts.all? do |edge, count|
                  boundary_edges.include?(edge) ? count == 1 : count == 2
                end
            end

            def boundary_ear_area_preserved?(source_triangle, triangles)
              source_area = Math.sqrt(
                magnitude_squared(
                  cross(
                    subtract(source_triangle[1], source_triangle[0]),
                    subtract(source_triangle[2], source_triangle[0])
                  )
                )
              ) * 0.5
              output_area = triangles.sum do |triangle|
                Math.sqrt(
                  magnitude_squared(
                    cross(
                      subtract(triangle[1], triangle[0]),
                      subtract(triangle[2], triangle[0])
                    )
                  )
                ) * 0.5
              end
              tolerance = [
                source_area * 1.0e-8,
                @weld * @weld * 10.0,
                1.0e-18
              ].max
              (source_area - output_area).abs <= tolerance
            end

            def boundary_ear_same_triangle?(left, right)
              left.all? do |point|
                right.any? do |candidate|
                  squared_distance(point, candidate) <= @weld * @weld
                end
              end
            end
          end
        end
      end
    end
  end
end
