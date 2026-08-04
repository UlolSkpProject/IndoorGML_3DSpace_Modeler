# frozen_string_literal: true

require 'json'
require 'time'

require_relative '../indoor3d/validity/val3dity_runner'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Shadow-only study of cropping the more complex Boolean operand by the
        # opposite CellSpace bounding box. Production decisions are unchanged.
        module Val3dityRecheckClippedOperandProbe
          THREAD_KEY = :indoor_gml_recheck_clipped_operand_probe
          MARGIN_MULTIPLIER = 10.0

          class Recorder
            attr_reader :mesh_cache

            def initialize(metadata)
              @metadata = metadata
              @started_at = Time.now
              @started = monotonic_now
              @mesh_cache = {}
              @pairs = []
            end

            def add(record)
              @pairs << record
            end

            def snapshot
              {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'started_at' => @started_at.iso8601(6),
                'elapsed_ms' => ((monotonic_now - @started) * 1000.0).round(3),
                'metadata' => @metadata,
                'summary' => summary,
                'pairs' => @pairs.sort_by { |row| -row.fetch('source_face_count', 0).to_i }
              }
            end

            private

            def summary
              {
                'pair_count' => @pairs.length,
                'ok_count' => @pairs.count { |row| row['status'] == 'ok' },
                'error_count' => @pairs.count { |row| row['status'] == 'error' },
                'surface_miss_count' => @pairs.count { |row| row['surface_miss_requires_containment_test'] == true },
                'open_cap_graph_count' => @pairs.count { |row| row['cap_graph_closed'] == false },
                'hole_detected_count' => @pairs.count { |row| row.fetch('hole_loop_count', 0).to_i.positive? },
                'coplanar_crop_plane_count' => @pairs.count { |row| row.fetch('coplanar_crop_plane_triangle_count', 0).to_i.positive? }
              }
            end

            def monotonic_now
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end

          class Analyzer
            PLANES = [
              [:min_x, 0, :min], [:max_x, 0, :max],
              [:min_y, 1, :min], [:max_y, 1, :max],
              [:min_z, 2, :min], [:max_z, 2, :max]
            ].freeze

            def initialize(tolerance)
              @tolerance = tolerance.to_f.abs
              @margin = [@tolerance * MARGIN_MULTIPLIER, @tolerance].max
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

            def choose_source(group1, group2)
              face_count(group1) >= face_count(group2) ? [group1, group2, 0] : [group2, group1, 1]
            end

            def face_count(group)
              return 0 unless group&.valid? && group.respond_to?(:definition)

              group.definition.entities.grep(Sketchup::Face).count(&:valid?)
            end

            def cached_mesh(group, cell_id, cache)
              key = [group.object_id, cell_id.to_s]
              return [cache[key], true] if cache.key?(key)

              faces = Utils::Geometry.entity_faces_in_parent_space(group)
              cache[key] = {
                face_count: faces.length,
                triangles: faces.flat_map { |face| Array(face[:triangles]) }.map { |triangle| triangle.map { |point| xyz(point) } }
              }
              [cache[key], false]
            end

            # Candidate hierarchy:
            # 1) triangle AABB broad-phase
            # 2) vertex-in-box and edge-vs-box diagnostics
            # 3) six-plane triangle clipping as the authoritative test
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
                counts[:edge_bounds_hit_count] += edges(triangle).count { |a, b| segment_intersects_box?(a, b, crop) }

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

              planes = plane_segments.to_h { |plane, segments| [plane.to_s, analyze_plane(plane, segments)] }
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
                'surface_miss_requires_containment_test' => counts[:fully_inside_triangle_count].zero? && counts[:clipped_polygon_count].zero?,
                'cap_graph_closed' => planes.values.all? { |row| row['closed_graph'] == true },
                'hole_loop_count' => planes.values.sum { |row| row['hole_loop_count'].to_i },
                'planes' => planes
              }
            end

            def expanded_bounds(bounds)
              {
                min: [bounds.min.x.to_f - @margin, bounds.min.y.to_f - @margin, bounds.min.z.to_f - @margin],
                max: [bounds.max.x.to_f + @margin, bounds.max.y.to_f + @margin, bounds.max.z.to_f + @margin]
              }
            end

            def triangle_bounds(triangle)
              {
                min: 3.times.map { |axis| triangle.map { |point| point[axis] }.min },
                max: 3.times.map { |axis| triangle.map { |point| point[axis] }.max }
              }
            end

            def bounds_overlap?(a, b)
              3.times.all? do |axis|
                a[:min][axis] <= b[:max][axis] + @weld && b[:min][axis] <= a[:max][axis] + @weld
              end
            end

            def point_inside?(point, box)
              3.times.all? { |axis| point[axis] >= box[:min][axis] - @weld && point[axis] <= box[:max][axis] + @weld }
            end

            # Slab segment/AABB test. Edge comparison is more complete than
            # vertex-only selection, but it is still diagnostic rather than the
            # final predicate because a large triangle can cover a box while all
            # three edges stay outside it.
            def segment_intersects_box?(a, b, box)
              t_min = 0.0
              t_max = 1.0
              3.times do |axis|
                delta = b[axis] - a[axis]
                if delta.abs <= @weld
                  return false if a[axis] < box[:min][axis] - @weld || a[axis] > box[:max][axis] + @weld
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
                  output << plane_intersection(previous, current, axis, limit) unless previous_inside
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
              side == :min ? value >= limit - @weld : value <= limit + @weld
            end

            def plane_intersection(a, b, axis, limit)
              delta = b[axis] - a[axis]
              return a.dup if delta.abs <= @weld

              t = (limit - a[axis]) / delta
              3.times.map { |coordinate| a[coordinate] + ((b[coordinate] - a[coordinate]) * t) }
            end

            # Cap edges are collected from the fully clipped polygon, not from
            # original outside vertices. This captures endpoints introduced by
            # intersections with two or more box planes.
            def collect_cap_segments(polygon, box, plane_segments, counts)
              PLANES.each do |name, axis, side|
                limit = side == :min ? box[:min][axis] : box[:max][axis]
                if polygon.all? { |point| (point[axis] - limit).abs <= @weld }
                  counts[:coplanar_crop_plane_triangle_count] += 1
                  next
                end

                edges(polygon).each do |a, b|
                  next unless (a[axis] - limit).abs <= @weld && (b[axis] - limit).abs <= @weld
                  next if same_point?(a, b)

                  plane_segments[name] << [a, b]
                end
              end
            end

            def analyze_plane(plane, segments)
              points = {}
              graph_edges = segments.filter_map do |segment|
                keys = segment.map do |point|
                  key = point_key(point)
                  points[key] ||= point
                  key
                end
                keys[0] == keys[1] ? nil : keys.sort
              end.uniq

              adjacency = Hash.new { |hash, key| hash[key] = [] }
              graph_edges.each do |a, b|
                adjacency[a] << b
                adjacency[b] << a
              end
              degrees = adjacency.values.map { |neighbors| neighbors.uniq.length }
              closed = graph_edges.empty? || degrees.all? { |degree| degree == 2 }
              loops = closed ? extract_loops(graph_edges, adjacency, points) : []
              roles = classify_nesting(plane, loops)

              {
                'segment_count' => segments.length,
                'unique_edge_count' => graph_edges.length,
                'vertex_count' => adjacency.length,
                'degree_histogram' => degrees.tally.transform_keys(&:to_s),
                'closed_graph' => closed,
                'loop_count' => loops.length,
                'outer_loop_count' => roles.count { |row| row[:role] == :outer },
                'hole_loop_count' => roles.count { |row| row[:role] == :hole },
                'loop_areas' => roles.map { |row| row[:area].round(12) }
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
                  next_key = adjacency[current_key].uniq.find { |key| key != previous_key }
                  break unless next_key && unused.delete([current_key, next_key].sort)

                  previous_key = current_key
                  current_key = next_key
                  guard += 1
                  break if guard > graph_edges.length + 1
                end
                loops << loop_keys.map { |key| points[key] } if current_key == start_key && loop_keys.length >= 3
              end
              loops
            end

            def classify_nesting(plane, loops)
              polygons = loops.map { |loop| project_loop(plane, loop) }
              polygons.each_with_index.map do |polygon, index|
                depth = polygons.each_with_index.count do |other, other_index|
                  index != other_index && point_in_polygon?(polygon.first, other)
                end
                { role: depth.odd? ? :hole : :outer, area: polygon_area(polygon).abs }
              end
            end

            def project_loop(plane, loop)
              axis = plane.to_s.end_with?('_x') ? 0 : (plane.to_s.end_with?('_y') ? 1 : 2)
              loop.map do |point|
                axis == 0 ? [point[1], point[2]] : (axis == 1 ? [point[0], point[2]] : [point[0], point[1]])
              end
            end

            def point_in_polygon?(point, polygon)
              x, y = point
              inside = false
              previous = polygon[-1]
              polygon.each do |current|
                x1, y1 = previous
                x2, y2 = current
                crosses = ((y1 > y) != (y2 > y)) &&
                          (x < ((x2 - x1) * (y - y1) / ((y2 - y1).nonzero? || 1.0e-30)) + x1)
                inside = !inside if crosses
                previous = current
              end
              inside
            end

            def polygon_area(polygon)
              polygon.each_with_index.sum do |(x1, y1), index|
                x2, y2 = polygon[(index + 1) % polygon.length]
                (x1 * y2) - (x2 * y1)
              end / 2.0
            end

            def edges(points)
              points.each_with_index.map { |point, index| [point, points[(index + 1) % points.length]] }
            end

            def deduplicate(points)
              result = []
              points.each { |point| result << point unless result.any? { |existing| same_point?(existing, point) } }
              result.pop if result.length > 1 && same_point?(result.first, result.last)
              result
            end

            def same_point?(a, b)
              3.times.all? { |axis| (a[axis] - b[axis]).abs <= @weld }
            end

            def point_key(point)
              point.map { |value| (value.to_f / @weld).round }
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

          class << self
            attr_reader :last_report_path, :last_snapshot

            def current
              Thread.current[THREAD_KEY]
            end

            def current=(recorder)
              Thread.current[THREAD_KEY] = recorder
            end

            def write_report(runner, recorder)
              snapshot = recorder.snapshot
              path = File.join(
                runner.instance_variable_get(:@work_dir),
                "#{runner.instance_variable_get(:@report_name)}_recheck_clipped_operand.json"
              )
              File.write(path, JSON.pretty_generate(snapshot), encoding: 'UTF-8')
              @last_report_path = path
              @last_snapshot = snapshot
              log("report: #{path}")
            rescue StandardError => e
              log("report write failed: #{e.class}: #{e.message}")
            end

            def log(message)
              text = "[IndoorGML][ClippedOperandProbe] #{message}"
              defined?(IndoorCore::Logger) ? IndoorCore::Logger.puts(text) : puts(text)
            rescue StandardError
              nil
            end
          end

          module RunnerPatch
            private

            def recheck_overlap_errors!(raw_report, progress: nil, progress_step: nil)
              recorder = Recorder.new(
                'gml_path' => instance_variable_get(:@gml_path),
                'report_name' => instance_variable_get(:@report_name),
                'mode' => 'shadow_analysis_only'
              )
              Val3dityRecheckClippedOperandProbe.current = recorder
              super
            ensure
              Val3dityRecheckClippedOperandProbe.write_report(self, recorder) if recorder
              Val3dityRecheckClippedOperandProbe.current = nil
            end
          end

          module RecheckerPatch
            private

            def model_solid_intersection_for_pair(group1, group2, cell_id1, cell_id2)
              recorder = Val3dityRecheckClippedOperandProbe.current
              record = Analyzer.new(instance_variable_get(:@tolerance)).analyze(
                group1, group2, [cell_id1, cell_id2], recorder.mesh_cache
              ) if recorder

              result = super
              if record
                record['original_intersection_status'] = result[:status].to_s if result.is_a?(Hash)
                record['original_intersection_reason'] = result[:reason].to_s if result.is_a?(Hash) && result[:reason]
                record['original_intersection_volume_in3'] = result[:volume] if result.is_a?(Hash)
                record['original_intersection_component_count'] = result[:component_count] if result.is_a?(Hash)
                recorder.add(record)
              end
              result
            rescue StandardError => e
              if record && recorder
                record['original_intersection_error'] = "#{e.class}: #{e.message}"
                recorder.add(record)
              end
              raise
            end
          end
        end
      end
    end
  end
end

runner = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityRunner
rechecker = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityOverlapGeometryRechecker
probe = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityRecheckClippedOperandProbe
runner.prepend(probe::RunnerPatch) unless runner.ancestors.include?(probe::RunnerPatch)
rechecker.prepend(probe::RecheckerPatch) unless rechecker.ancestors.include?(probe::RecheckerPatch)
probe.log('loaded: shadow analysis only; production decisions unchanged')
