# frozen_string_literal: true

require_relative '../indoor3d/validity/val3dity_overlap_geometry_rechecker'
require_relative 'val3dity_recheck_clipped_operand_probe_v3'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only v3 proxy path that reconstructs source∩crop-box directly from
        # clipped source triangles and planar cap regions. It does not use a
        # SketchUp Boolean to crop the source operand. The only native Boolean is
        # the final proxy-versus-target intersection.
        module Val3dityRecheckV3MeshProxy
          MODE = 'v3_direct_clipped_mesh_proxy_then_target_boolean'
          GUARD_MARGIN_MM = 5.0
          LEAF_TRIANGLE_COUNT = 12

          V3Probe = Val3dityRecheckClippedOperandProbeV3
          BaseProbe = Val3dityRecheckClippedOperandProbe

          class RebuildAnalyzer < V3Probe::Analyzer
            PLANES = BaseProbe::Analyzer::PLANES

            def analyze_rebuild(group1, group2, cell_ids, cache)
              started = monotonic_now
              source, target, source_index = choose_source(group1, group2)
              source_id = cell_ids[source_index]
              target_id = cell_ids[1 - source_index]
              mesh, cache_hit = cached_rebuild_mesh(source, source_id, cache)
              crop = expanded_bounds(target.bounds)
              rebuilt = rebuild_geometry(mesh, crop)

              report = rebuilt.fetch(:report).merge(
                'status' => rebuilt[:error] ? 'error' : 'ok',
                'cells' => cell_ids.map(&:to_s),
                'source_cell' => source_id.to_s,
                'target_cell' => target_id.to_s,
                'source_operand_index' => source_index,
                'source_face_count' => mesh[:face_count],
                'source_triangle_count' => mesh[:triangles].length,
                'source_mesh_cache_hit' => cache_hit,
                'target_face_count' => face_count(target),
                'crop_margin_in' => @margin,
                'crop_margin_mm' => GUARD_MARGIN_MM,
                'analysis_ms' => elapsed_ms(started)
              )
              report['error'] = rebuilt[:error] if rebuilt[:error]

              {
                report: report,
                geometry: rebuilt[:geometry],
                source_index: source_index
              }
            rescue StandardError => e
              {
                report: {
                  'status' => 'error',
                  'cells' => cell_ids.map(&:to_s),
                  'error' => "#{e.class}: #{e.message}",
                  'analysis_ms' => elapsed_ms(started)
                },
                geometry: nil,
                source_index: nil
              }
            end

            private

            def cached_rebuild_mesh(group, cell_id, cache)
              key = [:v3_direct_mesh, group.object_id, cell_id.to_s]
              return [cache[key], true] if cache.key?(key)

              faces = Utils::Geometry.entity_faces_in_parent_space(group)
              triangles = faces.flat_map { |face| Array(face[:triangles]) }.map do |triangle|
                triangle.map { |point| xyz(point) }
              end
              bounds = triangles.map { |triangle| triangle_bounds(triangle) }
              indices = (0...triangles.length).to_a
              cache[key] = {
                face_count: faces.length,
                triangles: triangles,
                triangle_bounds: bounds,
                bvh: build_bvh(bounds, indices)
              }
              [cache[key], false]
            end

            def rebuild_geometry(mesh, crop)
              counts = Hash.new(0)
              plane_segments = PLANES.to_h { |name, _axis, _side| [name, []] }
              clipped_triangles = []
              candidate_indices = query_box(mesh[:bvh], crop).select do |index|
                bounds_overlap?(mesh[:triangle_bounds].fetch(index), crop)
              end.sort
              counts[:triangle_bounds_rejected] = mesh[:triangles].length - candidate_indices.length

              candidate_indices.each do |triangle_index|
                triangle = mesh[:triangles].fetch(triangle_index)
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
                polygon_triangles(clipped).each do |clipped_triangle|
                  next if degenerate_triangle?(clipped_triangle)

                  clipped_triangles << clipped_triangle
                  counts[:clipped_triangle_count] += 1
                end
                collect_cap_segments(clipped, crop, plane_segments, counts)
              end

              global = analyze_global_cap_surface(plane_segments)
              report = count_report(counts, global)
              return rebuild_error(report, 'surface_miss') if report['surface_miss_requires_containment_test']
              return rebuild_error(report, 'global_cap_open') unless global['closed_graph'] == true
              return rebuild_error(report, 'coplanar_crop_plane_triangle') if
                counts[:coplanar_crop_plane_triangle_count].positive?

              canonical_segments = canonical_plane_segments(plane_segments)
              cap_result = build_cap_triangles(canonical_segments, crop, mesh)
              report.merge!(cap_result.fetch(:report))
              return rebuild_error(report, cap_result[:error]) if cap_result[:error]

              cap_triangles = cap_result.fetch(:triangles)
              raw_triangles = clipped_triangles + cap_triangles
              return rebuild_error(report, 'reconstructed_mesh_empty') if raw_triangles.empty?

              # Cap triangulation can simplify collinear boundary vertices while
              # the clipped source surface keeps those vertices. That creates a
              # geometrically coincident but topologically open T-junction. Make
              # the complete triangle soup conforming before handing it to
              # SketchUp: every vertex lying on any triangle edge subdivides that
              # edge, and the affected triangle is retriangulated through its
              # centroid. This is geometry-agnostic and uses only the existing
              # weld tolerance.
              all_triangles = conforming_triangle_soup(raw_triangles)
              topology = triangle_soup_topology(all_triangles)
              report['reconstructed_topology'] = topology
              return rebuild_error(report, 'reconstructed_topology_open') unless
                topology['closed_two_manifold'] == true

              report['reconstructed_surface_triangle_count'] = clipped_triangles.length
              report['reconstructed_cap_triangle_count'] = cap_triangles.length
              report['reconstructed_raw_triangle_count'] = raw_triangles.length
              report['reconstructed_total_triangle_count'] = all_triangles.length

              {
                report: report,
                geometry: {
                  triangles: all_triangles,
                  clipped_surface_triangle_count: clipped_triangles.length,
                  cap_triangle_count: cap_triangles.length
                },
                error: nil
              }
            rescue StandardError => e
              rebuild_error(
                count_report(counts || {}, { 'closed_graph' => false, 'loop_count' => 0 }),
                "#{e.class}: #{e.message}"
              )
            end

            def count_report(counts, global)
              {
                'candidate_triangle_count' => counts[:candidate_triangle_count].to_i,
                'triangle_bounds_rejected' => counts[:triangle_bounds_rejected].to_i,
                'inside_vertex_count' => counts[:inside_vertex_count].to_i,
                'candidate_edge_count' => counts[:candidate_edge_count].to_i,
                'edge_bounds_hit_count' => counts[:edge_bounds_hit_count].to_i,
                'fully_inside_triangle_count' => counts[:fully_inside_triangle_count].to_i,
                'clipped_polygon_count' => counts[:clipped_polygon_count].to_i,
                'clipped_triangle_count' => counts[:clipped_triangle_count].to_i,
                'coplanar_crop_plane_triangle_count' =>
                  counts[:coplanar_crop_plane_triangle_count].to_i,
                'surface_miss_requires_containment_test' =>
                  counts[:fully_inside_triangle_count].to_i.zero? &&
                  counts[:clipped_polygon_count].to_i.zero?,
                'global_cap_graph_closed' => global['closed_graph'] == true,
                'global_cap_loop_count' => global['loop_count'].to_i,
                'global_cap' => global
              }
            end

            def rebuild_error(report, error)
              { report: report, geometry: nil, error: error.to_s }
            end

            def polygon_triangles(polygon)
              return [] if polygon.length < 3

              (1...(polygon.length - 1)).map do |index|
                [polygon[0], polygon[index], polygon[index + 1]]
              end
            end

            def degenerate_triangle?(triangle)
              a, b, c = triangle
              ab = subtract(b, a)
              ac = subtract(c, a)
              magnitude_squared(cross(ab, ac)) <= [@weld * @weld * 1.0e-6, 1.0e-24].max
            end

            # Applies the exact v3 endpoint welding and per-plane parity, but
            # returns the retained segment coordinates needed for cap building.
            def canonical_plane_segments(plane_segments)
              endpoint_points = []
              rows = []
              plane_segments.each do |plane, segments|
                segments.each do |segment|
                  indices = segment.map do |point|
                    endpoint_points << point
                    endpoint_points.length - 1
                  end
                  rows << [plane, indices]
                end
              end

              welding = weld_endpoints(endpoint_points)
              point_cluster = welding.fetch(:point_cluster)
              representatives = welding.fetch(:clusters).map { |cluster| cluster.fetch(:representative) }
              counts = Hash.new(0)
              rows.each do |plane, indices|
                a = point_cluster.fetch(indices[0])
                b = point_cluster.fetch(indices[1])
                next if a == b

                counts[[plane, *[a, b].sort]] += 1
              end

              retained = PLANES.to_h { |name, _axis, _side| [name, []] }
              counts.each do |(plane, a, b), count|
                next unless count.odd?

                retained[plane] << [representatives.fetch(a), representatives.fetch(b)]
              end
              retained
            end

            def build_cap_triangles(plane_segments, crop, mesh)
              triangles = []
              plane_reports = {}

              PLANES.each do |plane, _axis, _side|
                result = cap_plane(plane, plane_segments.fetch(plane), crop, mesh)
                plane_reports[plane.to_s] = result.fetch(:report)
                return {
                  triangles: [],
                  report: { 'cap_planes' => plane_reports },
                  error: result[:error]
                } if result[:error]

                triangles.concat(result.fetch(:triangles))
              end

              {
                triangles: triangles,
                report: {
                  'cap_planes' => plane_reports,
                  'cap_region_count' => plane_reports.values.sum { |row| row['inside_region_count'].to_i },
                  'cap_triangle_count' => triangles.length
                },
                error: nil
              }
            end

            def cap_plane(plane, segments, crop, mesh)
              rectangle = plane_rectangle(plane, crop)
              vertices = []
              segment_edges = []

              segments.each do |a3, b3|
                a = intern_2d(vertices, project_plane(plane, a3))
                b = intern_2d(vertices, project_plane(plane, b3))
                next if a == b

                segment_edges << [a, b].sort
              end
              rectangle.each { |point| intern_2d(vertices, point) }
              segment_edges.uniq!

              unless segment_components_touch_boundary?(segment_edges, vertices, rectangle)
                return cap_plane_error(segments, 'interior_plane_loop_requires_hole_triangulation')
              end

              graph_edges = segment_edges.dup
              rectangle_boundary_edges(vertices, rectangle).each do |edge|
                graph_edges << edge unless edge[0] == edge[1]
              end
              graph_edges.uniq!

              cycles = planar_face_cycles(graph_edges, vertices)
              positive_cycles = cycles.select do |cycle|
                polygon_area_2d(cycle.map { |index| vertices[index] }) > area_epsilon
              end

              cap_triangles = []
              inside_regions = 0
              positive_cycles.each do |cycle|
                polygon = simplify_polygon(cycle.map { |index| vertices[index] })
                next if polygon.length < 3

                ears = triangulate_polygon(polygon)
                return cap_plane_error(segments, 'cap_ear_clipping_failed') if ears.nil?
                next if ears.empty?

                sample2 = triangle_centroid_2d(ears.first)
                sample3 = unproject_plane(plane, sample2, crop)
                inside = point_inside_mesh(sample3, mesh)
                return cap_plane_error(segments, 'cap_region_classification_ambiguous') if inside.nil?
                next unless inside

                inside_regions += 1
                ears.each do |triangle2|
                  triangle3 = triangle2.map { |point| unproject_plane(plane, point, crop) }
                  cap_triangles << orient_cap_triangle(plane, triangle3)
                end
              end

              {
                triangles: cap_triangles,
                report: {
                  'input_segment_count' => segments.length,
                  'planar_vertex_count' => vertices.length,
                  'planar_edge_count' => graph_edges.length,
                  'positive_face_cycle_count' => positive_cycles.length,
                  'inside_region_count' => inside_regions,
                  'cap_triangle_count' => cap_triangles.length
                },
                error: nil
              }
            rescue StandardError => e
              cap_plane_error(segments, "#{e.class}: #{e.message}")
            end

            def cap_plane_error(segments, error)
              {
                triangles: [],
                report: {
                  'input_segment_count' => segments.length,
                  'inside_region_count' => 0,
                  'cap_triangle_count' => 0,
                  'error' => error.to_s
                },
                error: error.to_s
              }
            end

            def plane_rectangle(plane, crop)
              case plane
              when :min_x, :max_x
                [[crop[:min][1], crop[:min][2]], [crop[:max][1], crop[:min][2]],
                 [crop[:max][1], crop[:max][2]], [crop[:min][1], crop[:max][2]]]
              when :min_y, :max_y
                [[crop[:min][0], crop[:min][2]], [crop[:max][0], crop[:min][2]],
                 [crop[:max][0], crop[:max][2]], [crop[:min][0], crop[:max][2]]]
              else
                [[crop[:min][0], crop[:min][1]], [crop[:max][0], crop[:min][1]],
                 [crop[:max][0], crop[:max][1]], [crop[:min][0], crop[:max][1]]]
              end
            end

            def project_plane(plane, point)
              case plane
              when :min_x, :max_x then [point[1], point[2]]
              when :min_y, :max_y then [point[0], point[2]]
              else [point[0], point[1]]
              end
            end

            def unproject_plane(plane, point, crop)
              case plane
              when :min_x then [crop[:min][0], point[0], point[1]]
              when :max_x then [crop[:max][0], point[0], point[1]]
              when :min_y then [point[0], crop[:min][1], point[1]]
              when :max_y then [point[0], crop[:max][1], point[1]]
              when :min_z then [point[0], point[1], crop[:min][2]]
              else [point[0], point[1], crop[:max][2]]
              end
            end

            def intern_2d(vertices, point)
              existing = vertices.each_index.min_by do |index|
                squared_distance_2d(vertices[index], point)
              end
              if existing && squared_distance_2d(vertices[existing], point) <= @weld * @weld
                existing
              else
                vertices << point.map(&:to_f)
                vertices.length - 1
              end
            end

            def rectangle_boundary_edges(vertices, rectangle)
              min_u, max_u = [rectangle[0][0], rectangle[1][0]].minmax
              min_v, max_v = [rectangle[0][1], rectangle[3][1]].minmax
              sides = [
                vertices.each_index.select { |i| near?(vertices[i][1], min_v) }.sort_by { |i| vertices[i][0] },
                vertices.each_index.select { |i| near?(vertices[i][0], max_u) }.sort_by { |i| vertices[i][1] },
                vertices.each_index.select { |i| near?(vertices[i][1], max_v) }.sort_by { |i| -vertices[i][0] },
                vertices.each_index.select { |i| near?(vertices[i][0], min_u) }.sort_by { |i| -vertices[i][1] }
              ]
              sides.flat_map do |indices|
                indices.each_cons(2).map { |a, b| [a, b].sort }
              end.uniq
            end

            def segment_components_touch_boundary?(edges2d, vertices, rectangle)
              return true if edges2d.empty?

              adjacency = Hash.new { |hash, key| hash[key] = [] }
              edges2d.each do |a, b|
                adjacency[a] << b
                adjacency[b] << a
              end
              remaining = adjacency.keys.to_h { |key| [key, true] }
              until remaining.empty?
                start = remaining.keys.first
                stack = [start]
                component = []
                remaining.delete(start)
                until stack.empty?
                  current = stack.pop
                  component << current
                  adjacency[current].each do |neighbor|
                    next unless remaining.delete(neighbor)

                    stack << neighbor
                  end
                end
                return false unless component.any? do |index|
                  point_on_rectangle_boundary?(vertices[index], rectangle)
                end
              end
              true
            end

            def point_on_rectangle_boundary?(point, rectangle)
              min_u, max_u = [rectangle[0][0], rectangle[1][0]].minmax
              min_v, max_v = [rectangle[0][1], rectangle[3][1]].minmax
              near?(point[0], min_u) || near?(point[0], max_u) ||
                near?(point[1], min_v) || near?(point[1], max_v)
            end

            def planar_face_cycles(edges2d, vertices)
              adjacency = Hash.new { |hash, key| hash[key] = [] }
              edges2d.each do |a, b|
                adjacency[a] << b
                adjacency[b] << a
              end
              adjacency.each do |vertex, neighbors|
                neighbors.uniq!
                neighbors.sort_by! do |neighbor|
                  point = vertices[neighbor]
                  origin = vertices[vertex]
                  Math.atan2(point[1] - origin[1], point[0] - origin[0])
                end
              end

              visited = {}
              cycles = []
              edges2d.each do |a, b|
                [[a, b], [b, a]].each do |start|
                  next if visited[start]

                  cycle = []
                  current = start
                  guard = 0
                  loop do
                    from, to = current
                    break if visited[current]

                    visited[current] = true
                    cycle << from
                    neighbors = adjacency.fetch(to)
                    incoming_index = neighbors.index(from)
                    break unless incoming_index

                    next_vertex = neighbors[(incoming_index - 1) % neighbors.length]
                    current = [to, next_vertex]
                    guard += 1
                    break if current == start
                    break if guard > edges2d.length * 4 + 8
                  end
                  cycles << cycle if current == start && cycle.length >= 3
                end
              end
              cycles
            end

            def simplify_polygon(points)
              result = points.dup
              changed = true
              while changed && result.length > 3
                changed = false
                result.length.times do |index|
                  a = result[(index - 1) % result.length]
                  b = result[index]
                  c = result[(index + 1) % result.length]
                  next unless cross_2d(subtract_2d(b, a), subtract_2d(c, b)).abs <= area_epsilon

                  result.delete_at(index)
                  changed = true
                  break
                end
              end
              result
            end

            def triangulate_polygon(points)
              polygon = points.dup
              polygon.reverse! if polygon_area_2d(polygon).negative?
              indices = (0...polygon.length).to_a
              triangles = []
              guard = 0

              while indices.length > 3
                ear_found = false
                indices.length.times do |position|
                  prev = indices[(position - 1) % indices.length]
                  curr = indices[position]
                  nxt = indices[(position + 1) % indices.length]
                  a, b, c = polygon[prev], polygon[curr], polygon[nxt]
                  next unless cross_2d(subtract_2d(b, a), subtract_2d(c, b)) > area_epsilon
                  next if indices.any? do |candidate|
                    next false if candidate == prev || candidate == curr || candidate == nxt

                    point_in_triangle_2d?(polygon[candidate], a, b, c)
                  end

                  triangles << [a, b, c]
                  indices.delete_at(position)
                  ear_found = true
                  break
                end
                return nil unless ear_found

                guard += 1
                return nil if guard > polygon.length * polygon.length
              end
              triangles << indices.map { |index| polygon[index] } if indices.length == 3
              triangles
            end

            def point_in_triangle_2d?(point, a, b, c)
              c1 = cross_2d(subtract_2d(b, a), subtract_2d(point, a))
              c2 = cross_2d(subtract_2d(c, b), subtract_2d(point, b))
              c3 = cross_2d(subtract_2d(a, c), subtract_2d(point, c))
              epsilon = area_epsilon
              c1 >= -epsilon && c2 >= -epsilon && c3 >= -epsilon
            end

            def triangle_centroid_2d(triangle)
              [
                triangle.sum { |point| point[0] } / 3.0,
                triangle.sum { |point| point[1] } / 3.0
              ]
            end

            def orient_cap_triangle(plane, triangle)
              desired = case plane
                        when :min_x then [-1.0, 0.0, 0.0]
                        when :max_x then [1.0, 0.0, 0.0]
                        when :min_y then [0.0, -1.0, 0.0]
                        when :max_y then [0.0, 1.0, 0.0]
                        when :min_z then [0.0, 0.0, -1.0]
                        else [0.0, 0.0, 1.0]
                        end
              normal = cross(subtract(triangle[1], triangle[0]), subtract(triangle[2], triangle[0]))
              dot(normal, desired).negative? ? [triangle[0], triangle[2], triangle[1]] : triangle
            end

            def point_inside_mesh(point, mesh)
              directions = [
                [1.0, 0.371390676, 0.217481243],
                [0.193117843, 1.0, 0.417291033],
                [0.317819431, 0.229143117, 1.0]
              ]
              votes = directions.map do |direction|
                ray_parity(point, direction, mesh)
              end.compact
              return nil if votes.empty?

              true_count = votes.count(true)
              false_count = votes.count(false)
              return true if true_count > false_count
              return false if false_count > true_count

              nil
            end

            def ray_parity(origin, direction, mesh)
              indices = query_ray(mesh[:bvh], origin, direction)
              hits = indices.filter_map do |index|
                ray_triangle_t(origin, direction, mesh[:triangles].fetch(index))
              end.select { |value| value > @weld }
              hits.sort!
              unique = []
              tolerance = [@weld * 4.0, 1.0e-9].max
              hits.each do |value|
                unique << value if unique.empty? || (value - unique[-1]).abs > tolerance
              end
              unique.length.odd?
            end

            def ray_triangle_t(origin, direction, triangle)
              v0, v1, v2 = triangle
              edge1 = subtract(v1, v0)
              edge2 = subtract(v2, v0)
              h = cross(direction, edge2)
              determinant = dot(edge1, h)
              epsilon = 1.0e-12
              return nil if determinant.abs <= epsilon

              inverse = 1.0 / determinant
              s = subtract(origin, v0)
              u = inverse * dot(s, h)
              return nil if u < -epsilon || u > 1.0 + epsilon

              q = cross(s, edge1)
              v = inverse * dot(direction, q)
              return nil if v < -epsilon || u + v > 1.0 + epsilon

              inverse * dot(edge2, q)
            end

            def conforming_triangle_soup(triangles)
              flattened = triangles.flatten(1)
              welding = weld_endpoints(flattened)
              point_cluster = welding.fetch(:point_cluster)
              representatives = welding.fetch(:clusters).map do |cluster|
                cluster.fetch(:representative).map(&:to_f)
              end

              welded_triangles = triangles.each_index.map do |triangle_index|
                offset = triangle_index * 3
                3.times.map do |corner|
                  representatives.fetch(point_cluster.fetch(offset + corner))
                end
              end
              candidate_vertices = representatives

              welded_triangles.flat_map do |triangle|
                conforming_subdivide_triangle(triangle, candidate_vertices)
              end
            end

            def conforming_subdivide_triangle(triangle, candidate_vertices)
              return [] if degenerate_triangle?(triangle)

              boundary = []
              3.times do |edge_index|
                a = triangle[edge_index]
                b = triangle[(edge_index + 1) % 3]
                edge_points = candidate_vertices.filter_map do |point|
                  parameter = point_on_segment_parameter(point, a, b)
                  [parameter, point] if parameter
                end
                edge_points.sort_by! { |parameter, point| [parameter, *point] }
                edge_points.each_with_index do |(_parameter, point), index|
                  next if edge_index.positive? && index.zero?
                  next if edge_index == 2 && index == edge_points.length - 1

                  boundary << point
                end
              end
              boundary = deduplicate_cycle_points(boundary)
              return [triangle] if boundary.length == 3
              return [] if boundary.length < 3

              centroid = 3.times.map do |axis|
                triangle.sum { |point| point[axis].to_f } / 3.0
              end
              reference_normal = cross(
                subtract(triangle[1], triangle[0]),
                subtract(triangle[2], triangle[0])
              )

              boundary.each_with_index.filter_map do |point, index|
                following = boundary[(index + 1) % boundary.length]
                candidate = [centroid, point, following]
                next if degenerate_triangle?(candidate)

                normal = cross(
                  subtract(candidate[1], candidate[0]),
                  subtract(candidate[2], candidate[0])
                )
                dot(normal, reference_normal).negative? ?
                  [candidate[0], candidate[2], candidate[1]] : candidate
              end
            end

            def point_on_segment_parameter(point, a, b)
              ab = subtract(b, a)
              length_squared = magnitude_squared(ab)
              return nil if length_squared <= 1.0e-30

              ap = subtract(point, a)
              parameter = dot(ap, ab) / length_squared
              epsilon = [@weld / Math.sqrt(length_squared), 1.0e-12].max
              return nil if parameter < -epsilon || parameter > 1.0 + epsilon

              clamped = [[parameter, 0.0].max, 1.0].min
              projected = 3.times.map { |axis| a[axis] + ab[axis] * clamped }
              distance_squared = squared_distance(point, projected)
              return nil if distance_squared > (@weld * @weld)

              clamped
            end

            def deduplicate_cycle_points(points)
              result = []
              points.each do |point|
                next if result.any? && squared_distance(result[-1], point) <= @weld * @weld

                result << point
              end
              if result.length > 1 &&
                 squared_distance(result[0], result[-1]) <= @weld * @weld
                result.pop
              end
              result
            end

            def triangle_soup_topology(triangles)
              flattened = triangles.flatten(1)
              welding = weld_endpoints(flattened)
              point_cluster = welding.fetch(:point_cluster)
              edge_counts = Hash.new(0)
              degenerate_count = 0

              triangles.each_index do |triangle_index|
                offset = triangle_index * 3
                vertices = 3.times.map do |corner|
                  point_cluster.fetch(offset + corner)
                end
                if vertices.uniq.length < 3
                  degenerate_count += 1
                  next
                end

                3.times do |edge_index|
                  a = vertices[edge_index]
                  b = vertices[(edge_index + 1) % 3]
                  edge_counts[[a, b].sort] += 1
                end
              end

              histogram = edge_counts.values.tally.transform_keys(&:to_s).sort.to_h
              boundary_count = edge_counts.count { |_edge, count| count == 1 }
              non_manifold_count = edge_counts.count { |_edge, count| count > 2 }
              {
                'triangle_count' => triangles.length,
                'welded_vertex_count' => welding.fetch(:clusters).length,
                'unique_edge_count' => edge_counts.length,
                'edge_occurrence_histogram' => histogram,
                'boundary_edge_count' => boundary_count,
                'non_manifold_edge_count' => non_manifold_count,
                'degenerate_triangle_count' => degenerate_count,
                'closed_two_manifold' =>
                  boundary_count.zero? && non_manifold_count.zero? && degenerate_count.zero?
              }
            end

            def build_bvh(bounds, indices)
              return nil if indices.empty?

              node_bounds = union_bounds(indices.map { |index| bounds.fetch(index) })
              if indices.length <= LEAF_TRIANGLE_COUNT
                return { min: node_bounds[:min], max: node_bounds[:max], indices: indices.freeze }
              end

              extents = 3.times.map { |axis| node_bounds[:max][axis] - node_bounds[:min][axis] }
              axis = extents.each_with_index.max_by { |value, _index| value }[1]
              sorted = indices.sort_by do |index|
                triangle_bound = bounds.fetch(index)
                (triangle_bound[:min][axis] + triangle_bound[:max][axis]) * 0.5
              end
              middle = sorted.length / 2
              {
                min: node_bounds[:min],
                max: node_bounds[:max],
                left: build_bvh(bounds, sorted[0...middle]),
                right: build_bvh(bounds, sorted[middle..])
              }
            end

            def union_bounds(bounds)
              {
                min: 3.times.map { |axis| bounds.map { |row| row[:min][axis] }.min },
                max: 3.times.map { |axis| bounds.map { |row| row[:max][axis] }.max }
              }
            end

            def query_box(node, box, output = [])
              return output unless node
              return output unless bounds_overlap?({ min: node[:min], max: node[:max] }, box)

              if node[:indices]
                output.concat(node[:indices])
              else
                query_box(node[:left], box, output)
                query_box(node[:right], box, output)
              end
              output
            end

            def query_ray(node, origin, direction, output = [])
              return output unless node
              return output unless ray_hits_bounds?(origin, direction, node[:min], node[:max])

              if node[:indices]
                output.concat(node[:indices])
              else
                query_ray(node[:left], origin, direction, output)
                query_ray(node[:right], origin, direction, output)
              end
              output
            end

            def ray_hits_bounds?(origin, direction, min, max)
              t_min = 0.0
              t_max = Float::INFINITY
              3.times do |axis|
                if direction[axis].abs <= 1.0e-15
                  return false if origin[axis] < min[axis] - @weld || origin[axis] > max[axis] + @weld
                  next
                end

                t1 = (min[axis] - origin[axis]) / direction[axis]
                t2 = (max[axis] - origin[axis]) / direction[axis]
                near_t, far_t = [t1, t2].minmax
                t_min = [t_min, near_t].max
                t_max = [t_max, far_t].min
                return false if t_min > t_max
              end
              t_max >= 0.0
            end

            def near?(a, b)
              (a.to_f - b.to_f).abs <= @weld * 2.0
            end

            def area_epsilon
              [@weld * @weld * 1.0e-4, 1.0e-18].max
            end

            def polygon_area_2d(points)
              points.each_with_index.sum do |point, index|
                following = points[(index + 1) % points.length]
                point[0] * following[1] - following[0] * point[1]
              end * 0.5
            end

            def squared_distance_2d(a, b)
              dx = a[0].to_f - b[0].to_f
              dy = a[1].to_f - b[1].to_f
              dx * dx + dy * dy
            end

            def subtract(a, b)
              3.times.map { |axis| a[axis].to_f - b[axis].to_f }
            end

            def subtract_2d(a, b)
              [a[0].to_f - b[0].to_f, a[1].to_f - b[1].to_f]
            end

            def cross(a, b)
              [
                a[1] * b[2] - a[2] * b[1],
                a[2] * b[0] - a[0] * b[2],
                a[0] * b[1] - a[1] * b[0]
              ]
            end

            def cross_2d(a, b)
              a[0] * b[1] - a[1] * b[0]
            end

            def dot(a, b)
              3.times.sum { |axis| a[axis] * b[axis] }
            end

            def magnitude_squared(vector)
              dot(vector, vector)
            end
          end

          class Rechecker < Val3dityOverlapGeometryRechecker
            attr_reader :proxy_records, :mesh_cache

            def initialize(**options)
              super
              @rebuild_analyzer = RebuildAnalyzer.new(options.fetch(:tolerance))
              @mesh_cache = {}
              @proxy_records = {}
            end

            def proxy_record(cell_id1, cell_id2)
              @proxy_records[pair_key_for_proxy(cell_id1, cell_id2)]
            end

            private

            def model_solid_intersection_for_pair(group1, group2, cell_id1, cell_id2)
              started = clock
              cells = [cell_id1.to_s, cell_id2.to_s]
              record = {
                'cells' => cells,
                'mode' => MODE,
                'guard_margin_mm' => GUARD_MARGIN_MM,
                'path' => nil,
                'fallback_reason' => nil
              }

              analysis_started = clock
              analyzed = @rebuild_analyzer.analyze_rebuild(group1, group2, cells, @mesh_cache)
              record['analysis_elapsed_ms'] = elapsed_ms(analysis_started)
              report = analyzed.fetch(:report)
              record['v3_analysis'] = report

              if report['status'] != 'ok' || analyzed[:geometry].nil?
                return original_fallback(
                  record, group1, group2, cell_id1, cell_id2,
                  report['error'] || 'rebuild_analysis_failed', started
                )
              end

              source_index = analyzed.fetch(:source_index)
              source = source_index.zero? ? group1 : group2
              target = source_index.zero? ? group2 : group1
              record['source_operand_index'] = source_index
              record['source_cell'] = cells[source_index]
              record['target_cell'] = cells[1 - source_index]

              proxy_result = direct_proxy_intersection(
                source, target, cells, analyzed.fetch(:geometry), record
              )
              if proxy_result[:fallback]
                return original_fallback(
                  record, group1, group2, cell_id1, cell_id2,
                  proxy_result[:fallback_reason] || 'direct_proxy_failed', started
                )
              end

              record['path'] = 'v3_direct_mesh_proxy'
              record['intersection_status'] = proxy_result[:status].to_s
              record['intersection_reason'] = proxy_result[:reason].to_s if proxy_result[:reason]
              record['intersection_volume_in3'] = proxy_result[:volume] if proxy_result.key?(:volume)
              record['intersection_component_count'] = proxy_result[:component_count] if
                proxy_result.key?(:component_count)
              record['total_elapsed_ms'] = elapsed_ms(started)
              store_record(record)
              proxy_result
            rescue StandardError => e
              record ||= { 'cells' => cells || [cell_id1.to_s, cell_id2.to_s], 'mode' => MODE }
              record['proxy_exception'] = "#{e.class}: #{e.message}"
              original_fallback(
                record, group1, group2, cell_id1, cell_id2,
                'proxy_exception', started || clock
              )
            end

            def direct_proxy_intersection(source, target, cell_ids, geometry, record)
              model = @model || Sketchup.active_model
              return fallback_result('model_unavailable') unless model
              return fallback_result('input_not_manifold') unless
                valid_manifold_group?(source) && valid_manifold_group?(target)

              proxy = nil
              target_copy = nil
              result = nil
              outcome = @indoor_model.with_indoor_model_operation(
                'IndoorGML v3 direct mesh proxy recheck', rollback: true
              ) do
                proxy_started = clock
                proxy = build_proxy_group(source, geometry.fetch(:triangles))
                record['proxy_build_elapsed_ms'] = elapsed_ms(proxy_started)
                next fallback_result('proxy_build_failed') unless proxy

                record['proxy_face_count'] = valid_faces(proxy).length
                record['proxy_edge_count'] = valid_edges(proxy).length
                record['proxy_surface_triangle_count'] = geometry[:clipped_surface_triangle_count]
                record['proxy_cap_triangle_count'] = geometry[:cap_triangle_count]
                next fallback_result('proxy_not_manifold') unless valid_manifold_group?(proxy)

                proxy_volume = solid_group_volume(proxy)
                next fallback_result('proxy_nonpositive_volume') unless proxy_volume&.positive?
                record['proxy_volume_in3'] = proxy_volume

                target_started = clock
                target_copy = build_boolean_copy(target)
                record['target_copy_elapsed_ms'] = elapsed_ms(target_started)
                next fallback_result('target_copy_failed') unless target_copy
                next fallback_result('target_copy_not_manifold') unless valid_manifold_group?(target_copy)
                next fallback_result('target_boolean_unsupported') unless proxy.respond_to?(:intersect)

                boolean_started = clock
                result = proxy.intersect(target_copy)
                record['target_boolean_elapsed_ms'] = elapsed_ms(boolean_started)
                next fallback_result('target_boolean_failed') if result.nil?

                classify_proxy_result(result, cell_ids)
              end
              outcome
            rescue StandardError => e
              record['proxy_operation_exception'] = "#{e.class}: #{e.message}"
              fallback_result('proxy_operation_exception')
            ensure
              cleanup_entities(result, target_copy, proxy, source, target)
            end

            def build_proxy_group(source, triangles)
              parent = source.respond_to?(:parent) ? source.parent : nil
              entities = parent.respond_to?(:entities) ? parent.entities : nil
              return nil unless entities&.respond_to?(:add_group)

              group = entities.add_group
              group.name = '__IndoorGML_V3_DIRECT_PROXY__' if group.respond_to?(:name=)
              mesh = Geom::PolygonMesh.new
              triangles.each do |triangle|
                points = triangle.map { |point| Geom::Point3d.new(*point) }
                mesh.add_polygon(*points)
              end
              success = group.entities.fill_from_mesh(mesh, true, 0)
              unless success
                group.erase! if group.valid?
                return nil
              end
              group
            rescue StandardError
              group.erase! if group&.valid?
              nil
            end

            def classify_proxy_result(result, cell_ids)
              faces = valid_faces(result)
              edges = valid_edges(result)
              if faces.empty? && edges.empty?
                return {
                  status: :not_reproduced,
                  reason: 'NO_VALID_INTERSECTION_GROUP_RETURNED',
                  volume: 0.0,
                  component_count: 0
                }
              end
              return non_solid_intersection_result(result, faces, edges) unless
                valid_manifold_group?(result)

              volume = solid_group_volume(result)
              return non_solid_intersection_result(result, faces, edges) unless volume&.positive?

              cache_intersection_overlay_geometry(result, cell_ids, volume)
              {
                status: :reproduced,
                reason: 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION',
                volume: volume,
                component_count: face_components(faces).length
              }
            end

            def original_fallback(record, group1, group2, cell_id1, cell_id2, reason, started)
              fallback_started = clock
              result = super(group1, group2, cell_id1, cell_id2)
              record['path'] = 'original_full_recheck_fallback'
              record['fallback_reason'] = reason.to_s
              record['fallback_elapsed_ms'] = elapsed_ms(fallback_started)
              record['intersection_status'] = result[:status].to_s if result.is_a?(Hash)
              record['intersection_reason'] = result[:reason].to_s if result.is_a?(Hash) && result[:reason]
              record['intersection_volume_in3'] = result[:volume] if result.is_a?(Hash) && result.key?(:volume)
              record['intersection_component_count'] = result[:component_count] if
                result.is_a?(Hash) && result.key?(:component_count)
              record['total_elapsed_ms'] = elapsed_ms(started)
              store_record(record)
              result
            end

            def valid_faces(group)
              return [] unless group&.valid? && group.respond_to?(:definition)

              group.definition.entities.grep(Sketchup::Face).select(&:valid?)
            rescue StandardError
              []
            end

            def valid_edges(group)
              return [] unless group&.valid? && group.respond_to?(:definition)

              group.definition.entities.grep(Sketchup::Edge).select(&:valid?)
            rescue StandardError
              []
            end

            def fallback_result(reason)
              { fallback: true, fallback_reason: reason.to_s }
            end

            def cleanup_entities(*entities)
              protected = entities.last(2)
              entities[0...-2].compact.uniq(&:object_id).each do |entity|
                next if protected.include?(entity)
                next unless entity.respond_to?(:valid?) && entity.valid?

                entity.erase!
              rescue StandardError
                nil
              end
            end

            def store_record(record)
              cells = Array(record['cells'])
              @proxy_records[pair_key_for_proxy(cells[0], cells[1])] = record
            end

            def pair_key_for_proxy(cell_id1, cell_id2)
              [cell_id1.to_s, cell_id2.to_s].sort.join('|')
            end

            def elapsed_ms(started)
              ((clock - started) * 1000.0).round(3)
            end

            def clock
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end

          class << self
            def log(message)
              text = "[IndoorGML][V3MeshProxy] #{message}"
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
            'loaded: v3 direct clipped-mesh proxy; source crop Boolean removed, ' \
            'production code unchanged'
          )
        end
      end
    end
  end
end
