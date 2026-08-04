# frozen_string_literal: true

require_relative 'val3dity_recheck_clipped_operand_probe'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckClippedOperandProbe
          GUARD_MARGIN_MM_V2 = 5.0 unless const_defined?(:GUARD_MARGIN_MM_V2, false)

          class Recorder
            def snapshot
              {
                'schema_version' => 2,
                'generated_at' => Time.now.iso8601(6),
                'started_at' => @started_at.iso8601(6),
                'elapsed_ms' => ((monotonic_now - @started) * 1000.0).round(3),
                'metadata' => @metadata.merge(
                  'cap_topology_mode' => 'global_box_surface_boundary',
                  'guard_margin_mm' => GUARD_MARGIN_MM_V2
                ),
                'summary' => summary_v2,
                'pairs' => @pairs.sort_by { |row| -row.fetch('source_face_count', 0).to_i }
              }
            end

            private

            def summary_v2
              {
                'pair_count' => @pairs.length,
                'ok_count' => @pairs.count { |row| row['status'] == 'ok' },
                'error_count' => @pairs.count { |row| row['status'] == 'error' },
                'surface_miss_count' => @pairs.count { |row| row['surface_miss_requires_containment_test'] == true },
                'open_cap_graph_count' => @pairs.count { |row| row['global_cap_graph_closed'] == false },
                'global_open_cap_graph_count' => @pairs.count { |row| row['global_cap_graph_closed'] == false },
                'legacy_per_plane_open_cap_graph_count' => @pairs.count { |row| row['per_plane_cap_graph_closed'] == false },
                'global_loop_count' => @pairs.sum { |row| row.fetch('global_cap_loop_count', 0).to_i },
                'cross_plane_vertex_count' => @pairs.sum { |row| row.fetch('global_cross_plane_vertex_count', 0).to_i },
                'coplanar_crop_plane_count' => @pairs.count do |row|
                  row.fetch('coplanar_crop_plane_triangle_count', 0).to_i.positive?
                end
              }
            end
          end

          class Analyzer
            def initialize(tolerance)
              @tolerance = tolerance.to_f.abs
              @margin = GUARD_MARGIN_MM_V2 / 25.4
              @weld = [@tolerance, 1.0e-9].max
            end

            def analyze(group1, group2, cell_ids, cache)
              started = monotonic_now
              source, target, source_index = choose_source(group1, group2)
              source_id = cell_ids[source_index]
              target_id = cell_ids[1 - source_index]
              mesh, cache_hit = cached_mesh(source, source_id, cache)
              crop = expanded_bounds(target.bounds)
              result = analyze_triangles(mesh[:triangles], crop)

              result.merge(
                'status' => 'ok',
                'cells' => cell_ids.map(&:to_s),
                'source_cell' => source_id.to_s,
                'target_cell' => target_id.to_s,
                'source_operand_index' => source_index,
                'source_face_count' => mesh[:face_count],
                'source_triangle_count' => mesh[:triangles].length,
                'source_mesh_cache_hit' => cache_hit,
                'target_face_count' => face_count(target),
                'crop_margin_in' => @margin,
                'crop_margin_mm' => GUARD_MARGIN_MM_V2,
                'analysis_ms' => elapsed_ms(started)
              )
            rescue StandardError => e
              {
                'status' => 'error',
                'cells' => cell_ids.map(&:to_s),
                'error' => "#{e.class}: #{e.message}",
                'analysis_ms' => elapsed_ms(started)
              }
            end

            private

            # Per-plane chains can legitimately end on a crop-box edge and
            # continue on an adjacent crop plane. Therefore the authoritative
            # topology diagnostic is the union of all six plane segments in 3D.
            def analyze_triangles(triangles, crop)
              counts = Hash.new(0)
              plane_segments = PLANES.to_h { |name, _axis, _side| [name, []] }

              triangles.each do |triangle|
                unless bounds_overlap?(triangle_bounds(triangle), crop)
                  counts[:triangle_bounds_rejected] += 1
                  next
                end

                counts[:candidate_triangle_count] += 1
                inside_count = triangle.count { |point| point_inside?(point, crop) }
                counts[:inside_vertex_count] += inside_count
                counts[:candidate_edge_count] += 3
                counts[:edge_bounds_hit_count] += edges(triangle).count do |a, b|
                  segment_intersects_box?(a, b, crop)
                end

                clipped = if inside_count == 3
                            counts[:fully_inside_triangle_count] += 1
                            triangle
                          else
                            clip_to_box(triangle, crop)
                          end
                next if clipped.length < 3

                counts[:clipped_polygon_count] += 1 unless inside_count == 3
                counts[:clipped_triangle_count] += clipped.length - 2
                collect_cap_segments(clipped, crop, plane_segments, counts)
              end

              planes = plane_segments.to_h do |plane, segments|
                [plane.to_s, analyze_plane(plane, segments)]
              end
              global = analyze_global_cap_surface(plane_segments)
              per_plane_closed = planes.values.all? { |row| row['closed_graph'] == true }

              {
                'candidate_triangle_count' => counts[:candidate_triangle_count],
                'triangle_bounds_rejected' => counts[:triangle_bounds_rejected],
                'inside_vertex_count' => counts[:inside_vertex_count],
                'candidate_edge_count' => counts[:candidate_edge_count],
                'edge_bounds_hit_count' => counts[:edge_bounds_hit_count],
                'fully_inside_triangle_count' => counts[:fully_inside_triangle_count],
                'clipped_polygon_count' => counts[:clipped_polygon_count],
                'clipped_triangle_count' => counts[:clipped_triangle_count],
                'coplanar_crop_plane_triangle_count' => counts[:coplanar_crop_plane_triangle_count],
                'surface_miss_requires_containment_test' =>
                  counts[:fully_inside_triangle_count].zero? && counts[:clipped_polygon_count].zero?,
                'cap_graph_closed' => global['closed_graph'],
                'global_cap_graph_closed' => global['closed_graph'],
                'global_cap_loop_count' => global['loop_count'],
                'global_cross_plane_vertex_count' => global['cross_plane_vertex_count'],
                'per_plane_cap_graph_closed' => per_plane_closed,
                'per_plane_hole_loop_count' =>
                  planes.values.sum { |row| row['hole_loop_count'].to_i },
                'hole_classification_status' =>
                  global['closed_graph'] ? 'pending_box_surface_region_classification' : 'blocked_by_open_global_graph',
                'global_cap' => global,
                'planes' => planes
              }
            end

            def analyze_global_cap_surface(plane_segments)
              points = {}
              edge_planes = Hash.new { |hash, key| hash[key] = [] }

              plane_segments.each do |plane, segments|
                segments.each do |segment|
                  keys = segment.map do |point|
                    key = point_key(point)
                    points[key] ||= point
                    key
                  end
                  next if keys[0] == keys[1]

                  edge_planes[keys.sort] << plane.to_s
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

              degrees = adjacency.values.map { |neighbors| neighbors.uniq.length }
              closed = graph_edges.empty? || degrees.all? { |degree| degree == 2 }
              loops = closed ? extract_loops(graph_edges, adjacency, points) : []
              plane_span_histogram = edge_planes.values.map { |labels| labels.uniq.length }.tally

              {
                'segment_count' => plane_segments.values.sum(&:length),
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
                'open_endpoint_count' => degrees.count { |degree| degree == 1 }
              }
            end
          end

          log('loaded v2: 5 mm guard margin and global box-surface cap graph')
        end
      end
    end
  end
end
