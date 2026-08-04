# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_interior_loop_cap'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            unless private_method_defined?(:triangle_soup_topology_without_edge_fan_diagnostic)
              alias_method :triangle_soup_topology_without_edge_fan_diagnostic,
                           :triangle_soup_topology
            end

            private

            # Diagnostic-only augmentation. It never changes the triangle soup
            # or the existing closed-two-manifold hard gate. For failed soups it
            # records the incident triangle fan around boundary/non-manifold
            # edges so the next repair can target the actual general pattern.
            def triangle_soup_topology(triangles)
              report = triangle_soup_topology_without_edge_fan_diagnostic(
                triangles
              )
              return report if report['closed_two_manifold'] == true

              report.merge(edge_fan_diagnostic(triangles))
            rescue StandardError => e
              report.merge(
                'edge_fan_diagnostic_error' => "#{e.class}: #{e.message}"
              )
            end

            def edge_fan_diagnostic(triangles)
              flattened = triangles.flatten(1)
              welding = weld_endpoints(flattened)
              point_cluster = welding.fetch(:point_cluster)
              representatives = welding.fetch(:clusters).map do |cluster|
                cluster.fetch(:representative).map(&:to_f)
              end

              edge_incidents = Hash.new { |hash, key| hash[key] = [] }
              triangle_key_counts = Hash.new(0)

              triangles.each_with_index do |_triangle, triangle_index|
                offset = triangle_index * 3
                vertex_ids = 3.times.map do |corner|
                  point_cluster.fetch(offset + corner)
                end
                next if vertex_ids.uniq.length < 3

                triangle_key = vertex_ids.sort.freeze
                triangle_key_counts[triangle_key] += 1
                triangle_points = vertex_ids.map do |vertex_id|
                  representatives.fetch(vertex_id)
                end
                normal = diagnostic_unit_normal(triangle_points)

                3.times do |edge_index|
                  from_id = vertex_ids[edge_index]
                  to_id = vertex_ids[(edge_index + 1) % 3]
                  third_id = vertex_ids[(edge_index + 2) % 3]
                  edge_key = [from_id, to_id].sort.freeze
                  edge_incidents[edge_key] << {
                    'triangle_index' => triangle_index,
                    'triangle_vertex_ids' => vertex_ids,
                    'triangle_key' => triangle_key,
                    'edge_orientation' =>
                      (from_id == edge_key[0] && to_id == edge_key[1]) ? 1 : -1,
                    'third_vertex_id' => third_id,
                    'third_vertex' => representatives.fetch(third_id),
                    'unit_normal' => normal,
                    'normal_axis' => diagnostic_normal_axis(normal),
                    'twice_area' => diagnostic_twice_area(triangle_points)
                  }
                end
              end

              non_manifold = []
              boundary = []
              edge_incidents.each do |edge_key, incidents|
                count = incidents.length
                next if count == 2

                detail = diagnostic_edge_detail(
                  edge_key, incidents, representatives
                )
                if count == 1
                  boundary << detail
                elsif count > 2
                  non_manifold << detail
                end
              end

              duplicate_groups = triangle_key_counts.select do |_key, count|
                count > 1
              end

              {
                'edge_fan_diagnostic_schema_version' => 1,
                'exact_duplicate_triangle_group_count' =>
                  duplicate_groups.length,
                'exact_duplicate_triangle_occurrence_count' =>
                  duplicate_groups.values.sum,
                'boundary_edge_details' =>
                  boundary.sort_by { |row| row['edge_vertex_ids'] }.first(32),
                'non_manifold_edge_details' =>
                  non_manifold.sort_by { |row| row['edge_vertex_ids'] }.first(32)
              }
            end

            def diagnostic_edge_detail(edge_key, incidents, representatives)
              a = representatives.fetch(edge_key[0])
              b = representatives.fetch(edge_key[1])
              pair_details = incidents.each_with_index.flat_map do |left, i|
                ((i + 1)...incidents.length).map do |j|
                  diagnostic_incident_pair(
                    a, b, left, incidents[j]
                  )
                end
              end

              {
                'edge_vertex_ids' => edge_key,
                'edge_points' => [a, b],
                'edge_length' => Math.sqrt(squared_distance(a, b)),
                'occurrence_count' => incidents.length,
                'incident_triangle_indices' =>
                  incidents.map { |row| row['triangle_index'] },
                'incident_edge_orientation_histogram' =>
                  incidents.map { |row| row['edge_orientation'] }
                           .tally
                           .transform_keys(&:to_s)
                           .sort
                           .to_h,
                'incident_triangle_key_duplicate_count' =>
                  incidents.map { |row| row['triangle_key'] }
                           .tally
                           .count { |_key, count| count > 1 },
                'incident_triangles' => incidents.map do |row|
                  row.reject { |key, _value| key == 'triangle_key' }
                end,
                'pair_classification_counts' =>
                  pair_details.map { |row| row['classification'] }
                              .tally
                              .sort
                              .to_h,
                'incident_pairs' => pair_details
              }
            end

            def diagnostic_incident_pair(edge_a, edge_b, left, right)
              left_normal = left['unit_normal']
              right_normal = right['unit_normal']
              normal_dot = if left_normal && right_normal
                             dot(left_normal, right_normal)
                           end

              coplanar = diagnostic_coplanar_incidents?(
                edge_a, left, right
              )
              same_side = if coplanar
                            diagnostic_same_side_of_edge?(
                              edge_a, edge_b, left, right
                            )
                          end

              classification =
                if left['triangle_key'] == right['triangle_key']
                  'exact_duplicate_triangle'
                elsif coplanar && same_side
                  'coplanar_same_side'
                elsif coplanar && same_side == false
                  'coplanar_opposite_side'
                else
                  'non_coplanar'
                end

              {
                'triangle_indices' => [
                  left['triangle_index'],
                  right['triangle_index']
                ],
                'normal_dot' => normal_dot,
                'coplanar' => coplanar,
                'same_side_of_edge' => same_side,
                'third_vertex_distance' => Math.sqrt(
                  squared_distance(
                    left['third_vertex'],
                    right['third_vertex']
                  )
                ),
                'classification' => classification
              }
            end

            def diagnostic_coplanar_incidents?(edge_a, left, right)
              left_normal = left['unit_normal']
              right_normal = right['unit_normal']
              return false unless left_normal && right_normal
              return false unless dot(left_normal, right_normal).abs >= 0.999999

              diagnostic_point_plane_distance(
                right['third_vertex'], edge_a, left_normal
              ) <= @weld * 2.0 &&
                diagnostic_point_plane_distance(
                  left['third_vertex'], edge_a, right_normal
                ) <= @weld * 2.0
            end

            def diagnostic_same_side_of_edge?(edge_a, edge_b, left, right)
              edge = subtract(edge_b, edge_a)
              normal = left['unit_normal']
              return nil unless normal

              left_side = dot(
                cross(edge, subtract(left['third_vertex'], edge_a)),
                normal
              )
              right_side = dot(
                cross(edge, subtract(right['third_vertex'], edge_a)),
                normal
              )
              epsilon = [@weld * Math.sqrt(magnitude_squared(edge)), 1.0e-12].max
              return nil if left_side.abs <= epsilon || right_side.abs <= epsilon

              left_side * right_side > 0.0
            end

            def diagnostic_point_plane_distance(point, origin, unit_normal)
              dot(subtract(point, origin), unit_normal).abs
            end

            def diagnostic_unit_normal(triangle)
              normal = cross(
                subtract(triangle[1], triangle[0]),
                subtract(triangle[2], triangle[0])
              )
              magnitude = Math.sqrt(magnitude_squared(normal))
              return nil if magnitude <= 1.0e-30

              normal.map { |value| value / magnitude }
            end

            def diagnostic_twice_area(triangle)
              Math.sqrt(
                magnitude_squared(
                  cross(
                    subtract(triangle[1], triangle[0]),
                    subtract(triangle[2], triangle[0])
                  )
                )
              )
            end

            def diagnostic_normal_axis(normal)
              return nil unless normal

              axis = normal.each_with_index.max_by do |value, _index|
                value.abs
              end
              {
                'axis' => %w[x y z].fetch(axis[1]),
                'component' => axis[0],
                'axis_aligned' => axis[0].abs >= 0.999999
              }
            end
          end
        end
      end
    end
  end
end
