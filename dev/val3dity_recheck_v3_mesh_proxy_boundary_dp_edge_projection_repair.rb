# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_boundary_dp_area_diagnostic'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            unless private_method_defined?(:boundary_dp_build_boundary_without_edge_projection)
              alias_method :boundary_dp_build_boundary_without_edge_projection,
                           :boundary_dp_build_boundary
            end

            private

            # Dev-only candidate repair.
            #
            # A welded representative can be within the topology tolerance of a
            # source edge without lying exactly on that edge. Using the raw point
            # as a boundary vertex changes the source triangle area and can turn
            # the intended triangle into a larger quadrilateral. For repair
            # candidates only, assign the point to exactly one closest edge and
            # use its orthogonal projection on that edge as the boundary vertex.
            #
            # Existing conforming soups never enter this repair path. The caller
            # still requires area preservation and a closed two-manifold topology;
            # any failure keeps the original soup and falls back to the full
            # recheck path.
            def boundary_dp_build_boundary(triangle, candidate_vertices)
              corner_tolerance_squared = @weld * @weld
              edge_rows = Array.new(3) { [] }
              assigned_count = 0
              multi_edge_candidate_count = 0
              projected_count = 0
              projection_distances = []

              candidate_vertices.each do |point|
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

                multi_edge_candidate_count += 1 if matches.length > 1
                edge_index, parameter, distance_squared, projected =
                  matches.min_by do |row|
                    [row[2], (row[1] - 0.5).abs, row[0]]
                  end

                edge_rows.fetch(edge_index) << [
                  parameter,
                  projected,
                  distance_squared,
                  point
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
                rows.sort_by! do |parameter, projected, distance_squared, original|
                  [parameter, distance_squared, *projected, *original]
                end
                rows.each do |_parameter, projected, _distance_squared, _original|
                  next if squared_distance(boundary[-1], projected) <=
                          corner_tolerance_squared

                  boundary << projected
                end
              end
              boundary = boundary_dp_remove_repeated_vertices(boundary)

              max_projection = projection_distances.max.to_f
              [
                boundary,
                {
                  'candidate_vertex_count' => candidate_vertices.length,
                  'assigned_interior_vertex_count' => assigned_count,
                  'multi_edge_candidate_count' => multi_edge_candidate_count,
                  'edge_interior_vertex_counts' => edge_rows.map(&:length),
                  'boundary_vertex_count' => boundary.length,
                  'boundary_vertex_coordinate_mode' =>
                    'closest_edge_orthogonal_projection',
                  'projected_interior_vertex_count' => projected_count,
                  'max_projection_distance_in' => max_projection.round(15),
                  'max_projection_distance_mm' =>
                    (max_projection * 25.4).round(12)
                }
              ]
            end

            def boundary_dp_projected_edge_match(point, a, b)
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

              [parameter, distance_squared, projected]
            end
          end
        end
      end
    end
  end
end
