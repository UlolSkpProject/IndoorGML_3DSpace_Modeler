# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Deferred, non-destructive contraction of simple minimal 3+ cycles in
      # the AFTER graph. All loops are detected and evaluated against the SAME
      # original After snapshot; only then is a single batch graph constructed.
      #
      # Native certifies planar virtual Loop meshes against all Solid boundary Faces,
      # then prevalidates replacement centers and LOS to original nodes.
      # A replacement never gains an invented LOS edge. Overlapping cycles,
      # or cycles joined by an edge between nodes both being removed, are
      # conflicting and cannot be contracted in the same batch.
      #
      # State is immutable. No shortest-path/detour increase limit is imposed.
      # BEFORE and AFTER graphs are not mutated by this diagnostic stage.
      module ReferenceGraphLoopCollapser
        MAX_GRAPH_NODES = 192
        MAX_COLLAPSES = 256
        MAX_LOOP_VERTICES = 32
        MAX_SEARCH_STEPS = 150000
        MAX_TRIANGLE_LOOPS = 256
        MAX_LONG_LOOPS = 512
        GEOMETRY_EPSILON = 1.0e-8

        module_function

        def collapse(after_graph, verified_candidates)
          nodes = Array(after_graph.fetch(:nodes))
          edges = Array(after_graph.fetch(:edges))
          origins = Array(after_graph.fetch(:original_indices))

          return unchanged(after_graph) if nodes.length > MAX_GRAPH_NODES ||
                                           nodes.length != origins.length ||
                                           origins.first != 0

          # Only Native-certified virtual membranes can collapse.
          # AFTER may have absorbed some of the original nodes; require
          # the ENTIRE certified induced ring to survive unchanged.
          return unchanged(after_graph, 0, 0) if Array(verified_candidates).empty?

          candidates = Array(verified_candidates).each_with_object({}) do |record, lookup|
            vertices = Array(record[:vertices] || record[:triangle]).sort
            lookup[vertices] = record if vertices.length.between?(3, MAX_LOOP_VERTICES) &&
                                         vertices.uniq.length == vertices.length
          end
          loops = verified_cycles(nodes, edges, origins, candidates)
          return unchanged(after_graph, 0, 0) if loops.empty?

          # Freeze the detection snapshot logically: both eligibility and
          # conflict resolution use the original AFTER nodes and edges only.
          # Smaller loops have priority, with deterministic index ties.
          loops.sort_by! { |vertices| [loop_area(nodes, vertices).abs, vertices.length, vertices] }
          eligible = loops.filter_map do |vertices|
            original_ids = vertices.map { |index| origins[index] }
            next if original_ids.any?(&:nil?)

            state_loop = original_ids.include?(0)
            # Native prevalidates hole-free topology for ALL loops,
            # including State-containing cycles. Never allow the State
            # shortcut to bypass the enclosed-Hole guard.
            candidate = candidates[original_ids.sort]
            next unless candidate

            boundary = external_neighbors(vertices, edges)
            next if boundary.any? { |index| origins[index].nil? }

            if state_loop
              # Native's existing State edges must already reach ALL external
              # neighbors. State itself is retained, not regenerated.
              next unless boundary.all? { |index| edge_exists?(edges, 0, index) }
              removed = vertices.reject(&:zero?)
            else
              # Every external replacement edge was validated by Native LOS,
              # without a circle-overlap requirement.
              # Native has already validated the representative against
              # Room geometry and LOS. Circle radius is not a collapse gate.
              next unless candidate[:point]
              visible = Array(candidate[:visible_neighbors])
              next unless boundary.all? { |index| visible.include?(origins[index]) }
              removed = vertices
            end

            {
              vertices: vertices.freeze,
              removed: removed.freeze,
              boundary: boundary.freeze,
              state_loop: state_loop,
              candidate: candidate
            }.freeze
          end

          adjacency = Array.new(nodes.length) { {} }
          edges.each do |a, b|
            adjacency[a][b] = true
            adjacency[b][a] = true
          end

          selected = []
          reserved_vertices = {}
          eligible.each do |option|
            break if selected.length >= MAX_COLLAPSES

            # One node cannot belong to two contracts; even loops sharing
            # State are excluded from the same batch.
            next if option[:vertices].any? { |index| reserved_vertices[index] }

            # Although their triangles are disjoint, two candidates can have
            # edges between vertices that BOTH disappear. Keeping both would
            # demand a new centroid-to-centroid LOS not checked by Native.
            has_cross_edges = selected.any? do |prior|
              option[:removed].any? do |a|
                prior[:removed].any? { |b| adjacency[a].key?(b) }
              end
            end
            next if has_cross_edges

            selected << option
            option[:vertices].each { |index| reserved_vertices[index] = true }
          end

          return unchanged(after_graph, loops.length, eligible.length) if selected.empty?

          # Apply all selected contractions simultaneously. The original graph
          # is never updated between candidates.
          removed = {}
          selected.each { |option| option[:removed].each { |i| removed[i] = true } }
          survivors = (0...nodes.length).reject { |index| removed[index] }
          reindex = {}
          survivors.each_with_index { |old, index| reindex[old] = index }

          new_nodes = survivors.map { |i| nodes[i] }
          new_origins = survivors.map { |i| origins[i] }
          new_edges = edges.filter_map do |a, b|
            next if removed[a] || removed[b]
            [reindex[a], reindex[b]].sort
          end

          selected.each do |option|
            next if option[:state_loop] # Existing State-Neighbor edges survive.

            record = option[:candidate]
            new_index = new_nodes.length
            new_nodes << { point: record[:point], radius: record[:radius] }.freeze
            new_origins << nil
            option[:boundary].each do |neighbor|
              # This must always exist because of the conflict screening.
              target = reindex[neighbor]
              raise 'Deferred collapse unresolved boundary' unless target

              new_edges << [new_index, target].sort
            end
          end

          {
            nodes: new_nodes.freeze,
            edges: new_edges.uniq.sort.map(&:freeze).freeze,
            original_indices: new_origins.freeze,
            collapse_count: selected.length,
            loop_count: loops.length,
            triangle_count: loops.count { |cycle| cycle.length == 3 },
            eligible_count: eligible.length,
            merged_into: Array(after_graph[:merged_into])
          }.freeze
        end

        # Verify that a Native-certified ring is still induced in AFTER.
        # A valid Surface-Mesh certificate is never inferred in Ruby.
        def verified_cycles(nodes, edges, origins, certificates)
          index_of = {}
          origins.each_with_index do |original, index|
            index_of[original] = index unless original.nil?
          end
          adjacency = Array.new(nodes.length) { {} }
          edges.each do |a, b|
            next unless a.is_a?(Integer) && b.is_a?(Integer) &&
                        a.between?(0, nodes.length - 1) &&
                        b.between?(0, nodes.length - 1) && a != b

            adjacency[a][b] = true
            adjacency[b][a] = true
          end

          certificates.filter_map do |originals, record|
            ordered = Array(record[:vertices] || record[:triangle])
            next unless ordered.sort == originals
            vertices = ordered.map { |id| index_of[id] }
            next if vertices.any?(&:nil?) ||
                    vertices.uniq.length != vertices.length

            length = vertices.length
            next unless length.times.all? { |i|
              adjacency[vertices[i]].key?(vertices[(i + 1) % length])
            }
            members = vertices.to_h { |id| [id, true] }
            next unless vertices.all? { |id|
              adjacency[id].keys.count { |neighbor| members[neighbor] } == 2
            }
            vertices.freeze
          end
        end

        def unchanged(after_graph, loops = 0, eligible = 0)
          after_graph.merge(
            collapse_count: 0,
            loop_count: loops,
            triangle_count: loops,
            eligible_count: eligible
          ).freeze
        end

        def edge_exists?(edges, first, second)
          edges.any? { |a, b| (a == first && b == second) || (a == second && b == first) }
        end

        # Enumerate chordless cycles, not just 3-cycles. Only accept simple,
        # positive-area polygons without other surviving nodes in the interior.
        # The search is capped to keep debug redraw/cache generation bounded.
        def cycle_loops(nodes, edges)
          adj = Array.new(nodes.length) { {} }
          edges.each do |a, b|
            next unless a.is_a?(Integer) && b.is_a?(Integer)
            next if a.negative? || b.negative? || a >= nodes.length || b >= nodes.length || a == b

            adj[a][b] = true
            adj[b][a] = true
          end
          neighbors = adj.map { |map| map.keys.sort }
          found = []
          triangle_count = 0
          long_count = 0
          explored = 0

          nodes.length.times do |start|
            used = Array.new(nodes.length, false)
            used[start] = true
            path = [start]

            visit = lambda do |current|
              explored += 1
              next if explored > MAX_SEARCH_STEPS

              neighbors[current].each do |nxt|
                next if nxt <= start || used[nxt]
                next if path[1...-1].any? { |prev| adj[nxt].key?(prev) }

                if path.length >= 2 && adj[start].key?(nxt)
                  if path[1] < nxt
                    candidate = path + [nxt]
                    if candidate.length == 3
                      if triangle_count < MAX_TRIANGLE_LOOPS &&
                         simple_minimal_loop?(candidate, nodes)
                        found << candidate.freeze
                        triangle_count += 1
                      end
                    elsif long_count < MAX_LONG_LOOPS &&
                          simple_minimal_loop?(candidate, nodes)
                      found << candidate.freeze
                      long_count += 1
                    end
                  end
                  next
                end
                next if path.length >= MAX_LOOP_VERTICES

                used[nxt] = true
                path << nxt
                visit.call(nxt)
                path.pop
                used[nxt] = false
                break if explored > MAX_SEARCH_STEPS
              end
            end

            visit.call(start)
            break if explored > MAX_SEARCH_STEPS
          end
          found
        end

        # Keep historical direct callers working without restricting the
        # actual collapse routine to triangles.
        def cycle_triangles(nodes, edges)
          cycle_loops(nodes, edges).select { |loop| loop.length == 3 }
        end

        def loop_area(nodes, vertices)
          vertices.each_with_index.sum do |vertex, index|
            a = nodes[vertex][:point]
            b = nodes[vertices[(index + 1) % vertices.length]][:point]
            a.x * b.y - b.x * a.y
          end * 0.5
        end

        def orient_xy(a, b, c)
          (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        end

        def segments_touch?(a, b, c, d)
          u = orient_xy(a, b, c)
          v = orient_xy(a, b, d)
          w = orient_xy(c, d, a)
          x = orient_xy(c, d, b)
          return false if (u > GEOMETRY_EPSILON && v > GEOMETRY_EPSILON) ||
                          (u < -GEOMETRY_EPSILON && v < -GEOMETRY_EPSILON) ||
                          (w > GEOMETRY_EPSILON && x > GEOMETRY_EPSILON) ||
                          (w < -GEOMETRY_EPSILON && x < -GEOMETRY_EPSILON)

          [a.x, b.x].min <= [c.x, d.x].max + GEOMETRY_EPSILON &&
            [c.x, d.x].min <= [a.x, b.x].max + GEOMETRY_EPSILON &&
            [a.y, b.y].min <= [c.y, d.y].max + GEOMETRY_EPSILON &&
            [c.y, d.y].min <= [a.y, b.y].max + GEOMETRY_EPSILON
        end

        def inside_polygon?(point, polygon)
          inside = false
          polygon.each_with_index do |a, index|
            b = polygon[(index + 1) % polygon.length]
            ab = Math.hypot(b.x - a.x, b.y - a.y)
            return false if ab <= GEOMETRY_EPSILON
            if orient_xy(a, b, point).abs <= GEOMETRY_EPSILON * ab &&
               point.x.between?([a.x, b.x].min - GEOMETRY_EPSILON,
                                [a.x, b.x].max + GEOMETRY_EPSILON) &&
               point.y.between?([a.y, b.y].min - GEOMETRY_EPSILON,
                                [a.y, b.y].max + GEOMETRY_EPSILON)
              return false
            end
            if (a.y > point.y) != (b.y > point.y)
              at_x = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y)
              inside = !inside if point.x < at_x
            end
          end
          inside
        end

        def simple_minimal_loop?(cycle, nodes)
          # Conservative 3D safety gate: XY polygon tests do NOT certify
          # a noncoplanar cycle or prove its interior is Hole-free.
          # Native 3D loop certificates are currently disabled as well.
          heights = cycle.map { |index| nodes[index][:point]&.z }
          return false if heights.any?(&:nil?)
          return false if heights.max - heights.min > GEOMETRY_EPSILON
          return false if loop_area(nodes, cycle).abs <= GEOMETRY_EPSILON

          polygon = cycle.map { |index| nodes[index][:point] }
          return false if polygon.any?(&:nil?)
          count = polygon.length
          count.times do |i|
            a, b = polygon[i], polygon[(i + 1) % count]
            return false if Math.hypot(a.x - b.x, a.y - b.y) <= GEOMETRY_EPSILON
            ((i + 2)...count).each do |j|
              next if i.zero? && j == count - 1
              return false if segments_touch?(a, b, polygon[j], polygon[(j + 1) % count])
            end
          end

          chosen = cycle.to_h { |index| [index, true] }
          nodes.each_with_index do |node, index|
            next if chosen[index]
            return false if inside_polygon?(node[:point], polygon)
          end
          true
        end

        def external_neighbors(vertices, edges)
          members = vertices.to_h { |index| [index, true] }
          edges.flat_map do |a, b|
            if members[a] && !members[b]
              [b]
            elsif members[b] && !members[a]
              [a]
            else
              []
            end
          end.uniq.sort
        end
      end
    end
  end
end
