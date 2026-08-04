# frozen_string_literal: true

require_relative 'val3dity_recheck_clipped_operand_probe_v2'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Third-generation clipped-operand topology study.
        #
        # v2 remains untouched. v3 changes only the global cap graph assembly:
        # - endpoint welding searches all 27 neighboring spatial bins and checks
        #   the real Euclidean distance;
        # - a cluster is accepted only when its complete diameter stays within
        #   the original weld tolerance, preventing transitive over-welding;
        # - duplicate edges are reduced by odd/even parity per crop plane;
        # - edges retained on adjacent crop planes are unioned, not cancelled.
        module Val3dityRecheckClippedOperandProbeV3
          SCHEMA_VERSION = 3
          WELD_MODE = 'neighbor_bins_euclidean_bounded_cluster'
          EDGE_MODE = 'per_plane_parity_then_cross_plane_union'

          V2Probe = Val3dityRecheckClippedOperandProbe

          class Analyzer < V2Probe::Analyzer
            private

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
              plane_span_histogram = edge_planes.values.map { |labels| labels.uniq.length }.tally

              {
                'schema_version' => SCHEMA_VERSION,
                'weld_mode' => WELD_MODE,
                'edge_mode' => EDGE_MODE,
                'segment_count' => plane_segments.values.sum(&:length),
                'degenerate_segment_count' => degenerate_segment_count,
                'endpoint_occurrence_count' => endpoint_points.length,
                'weld_cluster_count' => clusters.length,
                'multi_member_weld_cluster_count' =>
                  clusters.count { |cluster| cluster.fetch(:members).length > 1 },
                'max_weld_cluster_size' =>
                  (clusters.map { |cluster| cluster.fetch(:members).length }.max || 0),
                'max_weld_distance_in' => Math.sqrt(welding.fetch(:max_diameter_squared)),
                'max_weld_distance_mm' =>
                  (Math.sqrt(welding.fetch(:max_diameter_squared)) * 25.4).round(12),
                'plane_edge_key_count' => plane_edge_counts.length,
                'retained_plane_edge_count' => retained_plane_edge_count,
                'cancelled_even_plane_edge_count' => cancelled_plane_edge_count,
                'cancelled_even_edge_occurrence_count' => cancelled_edge_occurrence_count,
                'retained_odd_duplicate_plane_edge_count' => odd_duplicate_plane_edge_count,
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
                candidates = neighboring_bins(bin).flat_map { |key| bins[key] }.uniq
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

                chosen = valid.min_by { |distance, cluster_index, _diameter| [distance, cluster_index] }
                if chosen
                  _distance, cluster_index, candidate_diameter = chosen
                  cluster = clusters.fetch(cluster_index)
                  cluster[:members] << point
                  cluster[:source_indices] << point_index
                  cluster[:diameter_squared] = candidate_diameter
                  max_diameter_squared = [max_diameter_squared, candidate_diameter].max
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

            def problem_vertices(degree_by_vertex, clusters, vertex_planes)
              degree_by_vertex.filter_map do |vertex, degree|
                next if degree == 2

                cluster = clusters.fetch(vertex)
                point = cluster.fetch(:representative)
                {
                  'vertex' => vertex,
                  'degree' => degree,
                  'point_in' => point.map { |value| value.to_f.round(12) },
                  'point_mm' => point.map { |value| (value.to_f * 25.4).round(9) },
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
          end

          class << self
            def log(message)
              text = "[IndoorGML][ClippedOperandProbeV3] #{message}"
              if defined?(IndoorCore::Logger) && IndoorCore::Logger.respond_to?(:puts)
                IndoorCore::Logger.puts(text)
              else
                puts(text)
              end
            rescue StandardError
              nil
            end
          end

          log(
            'loaded: neighbor-bin Euclidean welding and per-plane edge parity; ' \
            'v2 and production decisions unchanged'
          )
        end
      end
    end
  end
end
