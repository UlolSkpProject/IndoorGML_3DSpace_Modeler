# frozen_string_literal: true

require_relative '../../utils/geometry'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityClippedMeshRecheck
          # Shared geometry kernel for clipping the more complex CellSpace mesh
          # against an expanded bounding box of the opposite operand.
          class ClippedOperandAnalyzer
            GUARD_MARGIN_MM = 5.0
            PLANES = [
              [:min_x, 0, :min], [:max_x, 0, :max],
              [:min_y, 1, :min], [:max_y, 1, :max],
              [:min_z, 2, :min], [:max_z, 2, :max]
            ].freeze

            def initialize(tolerance)
              @tolerance = tolerance.to_f.abs
              @margin = GUARD_MARGIN_MM / 25.4
              @weld = [@tolerance, 1.0e-9].max
            end

            private

            def choose_source(group1, group2)
              face_count(group1) >= face_count(group2) ?
                [group1, group2, 0] : [group2, group1, 1]
            end

            def face_count(group)
              return 0 unless group&.valid? && group.respond_to?(:definition)

              group.definition.entities.grep(Sketchup::Face).count(&:valid?)
            end

            def expanded_bounds(bounds)
              {
                min: [
                  bounds.min.x.to_f - @margin,
                  bounds.min.y.to_f - @margin,
                  bounds.min.z.to_f - @margin
                ],
                max: [
                  bounds.max.x.to_f + @margin,
                  bounds.max.y.to_f + @margin,
                  bounds.max.z.to_f + @margin
                ]
              }
            end

            def triangle_bounds(triangle)
              {
                min: 3.times.map do |axis|
                  triangle.map { |point| point[axis] }.min
                end,
                max: 3.times.map do |axis|
                  triangle.map { |point| point[axis] }.max
                end
              }
            end

            def bounds_overlap?(a, b)
              3.times.all? do |axis|
                a[:min][axis] <= b[:max][axis] + @weld &&
                  b[:min][axis] <= a[:max][axis] + @weld
              end
            end

            def point_inside?(point, box)
              3.times.all? do |axis|
                point[axis] >= box[:min][axis] - @weld &&
                  point[axis] <= box[:max][axis] + @weld
              end
            end

            def segment_intersects_box?(a, b, box)
              t_min = 0.0
              t_max = 1.0
              3.times do |axis|
                delta = b[axis] - a[axis]
                if delta.abs <= @weld
                  return false if
                    a[axis] < box[:min][axis] - @weld ||
                    a[axis] > box[:max][axis] + @weld
                  next
                end

                t1 = (box[:min][axis] - a[axis]) / delta
                t2 = (box[:max][axis] - a[axis]) / delta
                near_t, far_t = [t1, t2].minmax
                t_min = [t_min, near_t].max
                t_max = [t_max, far_t].min
                return false if t_min > t_max + @weld
              end
              t_max >= -@weld && t_min <= 1.0 + @weld
            end

            def clip_to_box(triangle, box)
              polygon = triangle
              PLANES.each do |_name, axis, side|
                limit = side == :min ? box[:min][axis] : box[:max][axis]
                polygon = clip_halfspace(polygon, axis, side, limit)
                break if polygon.empty?
              end
              polygon
            end

            def clip_halfspace(polygon, axis, side, limit)
              return [] if polygon.empty?

              output = []
              previous = polygon[-1]
              previous_inside = inside_plane?(previous[axis], side, limit)
              polygon.each do |current|
                current_inside = inside_plane?(current[axis], side, limit)
                if current_inside
                  output << plane_intersection(
                    previous, current, axis, limit
                  ) unless previous_inside
                  output << current
                elsif previous_inside
                  output << plane_intersection(previous, current, axis, limit)
                end
                previous = current
                previous_inside = current_inside
              end
              deduplicate(output)
            end

            def inside_plane?(value, side, limit)
              side == :min ?
                value >= limit - @weld : value <= limit + @weld
            end

            def plane_intersection(a, b, axis, limit)
              delta = b[axis] - a[axis]
              return a.dup if delta.abs <= @weld

              t = (limit - a[axis]) / delta
              3.times.map do |coordinate|
                a[coordinate] + ((b[coordinate] - a[coordinate]) * t)
              end
            end

            def collect_cap_segments(polygon, box, plane_segments, counts)
              PLANES.each do |name, axis, side|
                limit = side == :min ? box[:min][axis] : box[:max][axis]
                if polygon.all? { |point| (point[axis] - limit).abs <= @weld }
                  counts[:coplanar_crop_plane_triangle_count] += 1
                  next
                end

                edges(polygon).each do |a, b|
                  next unless
                    (a[axis] - limit).abs <= @weld &&
                    (b[axis] - limit).abs <= @weld
                  next if same_point?(a, b)

                  plane_segments[name] << [a, b]
                end
              end
            end

            def analyze_global_cap_surface(plane_segments)
              endpoint_points = []
              segment_rows = []
              plane_segments.each do |plane, segments|
                segments.each do |segment|
                  endpoint_indices = segment.map do |point|
                    endpoint_points << point
                    endpoint_points.length - 1
                  end
                  segment_rows << {
                    plane: plane.to_s,
                    endpoint_indices: endpoint_indices
                  }
                end
              end

              welding = weld_endpoints(endpoint_points)
              point_cluster = welding.fetch(:point_cluster)
              clusters = welding.fetch(:clusters)
              points = clusters.each_with_index.to_h do |cluster, index|
                [index, cluster.fetch(:representative)]
              end

              plane_edge_counts = Hash.new(0)
              degenerate_segment_count = 0
              segment_rows.each do |row|
                a = point_cluster.fetch(row[:endpoint_indices][0])
                b = point_cluster.fetch(row[:endpoint_indices][1])
                if a == b
                  degenerate_segment_count += 1
                  next
                end
                edge = [a, b].sort
                plane_edge_counts[[row[:plane], edge[0], edge[1]]] += 1
              end

              edge_planes = Hash.new { |hash, key| hash[key] = [] }
              retained_plane_edge_count = 0
              cancelled_plane_edge_count = 0
              cancelled_edge_occurrence_count = 0
              odd_duplicate_plane_edge_count = 0
              plane_edge_counts.each do |(plane, a, b), count|
                if count.odd?
                  edge_planes[[a, b]] << plane
                  retained_plane_edge_count += 1
                  odd_duplicate_plane_edge_count += 1 if count > 1
                else
                  cancelled_plane_edge_count += 1
                  cancelled_edge_occurrence_count += count
                end
              end

              graph_edges = edge_planes.keys
              adjacency = Hash.new { |hash, key| hash[key] = [] }
              vertex_planes = Hash.new { |hash, key| hash[key] = [] }
              graph_edges.each do |a, b|
                adjacency[a] << b
                adjacency[b] << a
                labels = edge_planes[[a, b]].uniq
                vertex_planes[a].concat(labels)
                vertex_planes[b].concat(labels)
              end

              degree_by_vertex = adjacency.transform_values do |neighbors|
                neighbors.uniq.length
              end
              degrees = degree_by_vertex.values
              closed = graph_edges.empty? || degrees.all? { |degree| degree == 2 }
              loops = closed ? extract_loops(graph_edges, adjacency, points) : []
              plane_span_histogram = edge_planes.values.map do |labels|
                labels.uniq.length
              end.tally

              {
                'schema_version' => 1,
                'weld_mode' => 'neighbor_bins_euclidean_bounded_cluster',
                'edge_mode' => 'per_plane_parity_then_cross_plane_union',
                'segment_count' => plane_segments.values.sum(&:length),
                'degenerate_segment_count' => degenerate_segment_count,
                'endpoint_occurrence_count' => endpoint_points.length,
                'weld_cluster_count' => clusters.length,
                'multi_member_weld_cluster_count' =>
                  clusters.count { |cluster| cluster.fetch(:members).length > 1 },
                'max_weld_cluster_size' =>
                  (clusters.map { |cluster| cluster.fetch(:members).length }.max || 0),
                'max_weld_distance_in' =>
                  Math.sqrt(welding.fetch(:max_diameter_squared)),
                'max_weld_distance_mm' =>
                  (Math.sqrt(welding.fetch(:max_diameter_squared)) * 25.4).round(12),
                'plane_edge_key_count' => plane_edge_counts.length,
                'retained_plane_edge_count' => retained_plane_edge_count,
                'cancelled_even_plane_edge_count' => cancelled_plane_edge_count,
                'cancelled_even_edge_occurrence_count' =>
                  cancelled_edge_occurrence_count,
                'retained_odd_duplicate_plane_edge_count' =>
                  odd_duplicate_plane_edge_count,
                'unique_edge_count' => graph_edges.length,
                'vertex_count' => adjacency.length,
                'degree_histogram' => degrees.tally.transform_keys(&:to_s),
                'closed_graph' => closed,
                'loop_count' => loops.length,
                'cross_plane_vertex_count' =>
                  vertex_planes.count { |_key, labels| labels.uniq.length > 1 },
                'edge_plane_span_histogram' =>
                  plane_span_histogram.transform_keys(&:to_s),
                'non_manifold_vertex_count' => degrees.count { |degree| degree > 2 },
                'open_endpoint_count' => degrees.count { |degree| degree == 1 },
                'problem_vertices' => problem_vertices(
                  degree_by_vertex, clusters, vertex_planes
                )
              }
            end

            def weld_endpoints(points)
              bins = Hash.new { |hash, key| hash[key] = [] }
              clusters = []
              point_cluster = Array.new(points.length)
              tolerance_squared = @weld * @weld
              epsilon = [tolerance_squared * 1.0e-12, 1.0e-30].max
              max_diameter_squared = 0.0

              points.each_with_index do |point, point_index|
                bin = spatial_bin(point)
                candidates = neighboring_bins(bin).flat_map do |key|
                  bins[key]
                end.uniq
                valid = candidates.filter_map do |cluster_index|
                  cluster = clusters.fetch(cluster_index)
                  representative_distance = squared_distance(
                    point, cluster.fetch(:representative)
                  )
                  next if representative_distance > tolerance_squared + epsilon

                  member_distances = cluster.fetch(:members).map do |member|
                    squared_distance(point, member)
                  end
                  candidate_diameter = [
                    cluster.fetch(:diameter_squared),
                    member_distances.max.to_f
                  ].max
                  next if candidate_diameter > tolerance_squared + epsilon

                  [representative_distance, cluster_index, candidate_diameter]
                end

                chosen = valid.min_by do |distance, cluster_index, _diameter|
                  [distance, cluster_index]
                end
                if chosen
                  _distance, cluster_index, candidate_diameter = chosen
                  cluster = clusters.fetch(cluster_index)
                  cluster[:members] << point
                  cluster[:source_indices] << point_index
                  cluster[:diameter_squared] = candidate_diameter
                  max_diameter_squared = [
                    max_diameter_squared, candidate_diameter
                  ].max
                  point_cluster[point_index] = cluster_index
                else
                  cluster_index = clusters.length
                  clusters << {
                    representative: point,
                    members: [point],
                    source_indices: [point_index],
                    diameter_squared: 0.0
                  }
                  bins[bin] << cluster_index
                  point_cluster[point_index] = cluster_index
                end
              end

              {
                point_cluster: point_cluster,
                clusters: clusters,
                max_diameter_squared: max_diameter_squared
              }
            end

            def extract_loops(graph_edges, adjacency, points)
              unused = graph_edges.to_h { |edge| [edge, true] }
              loops = []
              until unused.empty?
                start_key, current_key = unused.keys.first
                previous_key = start_key
                loop_keys = [start_key]
                unused.delete([start_key, current_key].sort)
                guard = 0
                while current_key != start_key
                  loop_keys << current_key
                  next_key = adjacency[current_key].uniq.find do |key|
                    key != previous_key
                  end
                  break unless
                    next_key && unused.delete([current_key, next_key].sort)

                  previous_key = current_key
                  current_key = next_key
                  guard += 1
                  break if guard > graph_edges.length + 1
                end
                if current_key == start_key && loop_keys.length >= 3
                  loops << loop_keys.map { |key| points[key] }
                end
              end
              loops
            end

            def problem_vertices(degree_by_vertex, clusters, vertex_planes)
              degree_by_vertex.filter_map do |vertex, degree|
                next if degree == 2

                cluster = clusters.fetch(vertex)
                point = cluster.fetch(:representative)
                {
                  'vertex' => vertex,
                  'degree' => degree,
                  'point_in' => point.map { |value| value.to_f.round(12) },
                  'point_mm' => point.map do |value|
                    (value.to_f * 25.4).round(9)
                  end,
                  'planes' => vertex_planes[vertex].uniq.sort,
                  'weld_cluster_member_count' => cluster.fetch(:members).length,
                  'weld_cluster_diameter_mm' =>
                    (Math.sqrt(cluster.fetch(:diameter_squared)) * 25.4).round(12)
                }
              end
            end

            def spatial_bin(point)
              point.map { |value| (value.to_f / @weld).floor }
            end

            def neighboring_bins(bin)
              (-1..1).flat_map do |dx|
                (-1..1).flat_map do |dy|
                  (-1..1).map do |dz|
                    [bin[0] + dx, bin[1] + dy, bin[2] + dz]
                  end
                end
              end
            end

            def squared_distance(a, b)
              3.times.sum do |axis|
                delta = a[axis].to_f - b[axis].to_f
                delta * delta
              end
            end

            def edges(points)
              points.each_with_index.map do |point, index|
                [point, points[(index + 1) % points.length]]
              end
            end

            def deduplicate(points)
              result = []
              points.each do |point|
                result << point unless result.any? do |existing|
                  same_point?(existing, point)
                end
              end
              result.pop if
                result.length > 1 && same_point?(result.first, result.last)
              result
            end

            def same_point?(a, b)
              3.times.all? { |axis| (a[axis] - b[axis]).abs <= @weld }
            end

            def xyz(point)
              [point.x.to_f, point.y.to_f, point.z.to_f]
            end

            def elapsed_ms(started)
              ((monotonic_now - started) * 1000.0).round(3)
            end

            def monotonic_now
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end
        end
      end
    end
  end
end
