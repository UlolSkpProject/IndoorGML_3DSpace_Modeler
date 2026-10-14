# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Geometrically safe contraction of triangular cycles in the AFTER graph.
      #
      # The Native V6 output supplies geometry-validated centroid and LOS
      # neighbors for triangles in the ORIGINAL graph. We may only contract a
      # triangle that still survives After; no Ruby-side geometric inference
      # is allowed for new node positions or visibility edges.
      #
      # Re-run until no eligible ORIGINAL-vertex triangle remains. Loops
      # involving new synthetic centers are deliberately left alone because
      # they do not have an independently Native-validated replacement.
      module ReferenceGraphLoopCollapser
        MAX_GLOBAL_PATH_FACTOR = 1.25
        MAX_GRAPH_NODES = 192
        MAX_COLLAPSES = 256
        EPSILON = 1.0e-9

        module_function

        def collapse(after_graph, verified_candidates)
          nodes = Array(after_graph.fetch(:nodes)).dup
          edges = Array(after_graph.fetch(:edges)).map(&:dup)
          origins = Array(after_graph.fetch(:original_indices)).dup
          return unchanged(after_graph) if nodes.length > MAX_GRAPH_NODES ||
                                           nodes.length != origins.length ||
                                           verified_candidates.nil? ||
                                           Array(verified_candidates).empty? && !triangle_with_state?(edges)
          return unchanged(after_graph) unless origins.first == 0

          candidates = Array(verified_candidates).each_with_object({}) do |record, out|
            triple = Array(record[:triangle]).sort
            out[triple] = record if triple.size == 3 && triple.uniq.size == 3
          end

          baseline = {}
          origins.each_with_index do |id, index|
            baseline[id] = shortest_distances(nodes, edges, index) unless id.nil?
          end
          # Baseline distances are indexed by original AFTER node positions.
          origin_to_initial_index = {}
          origins.each_with_index { |id, i| origin_to_initial_index[id] = i unless id.nil? }

          iterations = 0
          while iterations < MAX_COLLAPSES
            triangles = cycle_triangles(nodes, edges)
            break if triangles.empty?

            changed = false
            triangles.sort_by! { |indices| [triangle_area(nodes, indices), indices] }
            triangles.each do |triple|
              ids = triple.map { |index| origins[index] }
              next if ids.any?(&:nil?)

              state_loop = ids.include?(0)
              candidate = state_loop ? nil : candidates[ids.sort]
              next unless state_loop || candidate
              boundary = external_neighbors(triple, edges)
              next if boundary.any? { |index| origins[index].nil? }

              retained_state = triple.include?(0)
              representative_index = retained_state ? 0 : nil
              if retained_state
                # Only preserve already validated, existing edges from State
                # to every external neighbor. No new LOS edges are invented.
                next unless boundary.all? { |index| edge_exists?(edges, 0, index) }
              else
                # A new representative requires Native-validated LOS to
                # every surviving boundary vertex. Circle overlap is used
                # only by the original graph, not by new collapse edges.
                visible = Array(candidate[:visible_neighbors])
                next unless boundary.all? { |index| visible.include?(origins[index]) }
              end

              proposal = contraction(nodes, edges, origins, triple, boundary,
                                     candidate, representative_index)
              next unless proposal
              new_nodes, new_edges, new_origins = proposal

              # Check path lengths against the immutable AFTER baseline,
              # not the previous collapse, preventing cumulative drift.
              next unless global_paths_preserved?(
                new_nodes, new_edges, new_origins, baseline, origin_to_initial_index
              )

              nodes, edges, origins = new_nodes, new_edges, new_origins
              iterations += 1
              changed = true
              break
            end
            break unless changed
          end

          {
            nodes: nodes.freeze,
            edges: edges.map(&:freeze).freeze,
            original_indices: origins.freeze,
            collapse_count: iterations,
            merged_into: Array(after_graph[:merged_into])
          }.freeze
        end

        def unchanged(after_graph)
          after_graph.merge(collapse_count: 0).freeze
        end

        def triangle_with_state?(edges)
          others = edges.filter_map do |a, b|
            a == 0 ? b : (b == 0 ? a : nil)
          end
          others.combination(2).any? { |a, b| edge_exists?(edges, a, b) }
        end

        def edge_exists?(edges, first, second)
          edges.any? { |a, b| (a == first && b == second) || (a == second && b == first) }
        end

        def cycle_triangles(nodes, edges)
          adj = Array.new(nodes.size) { {} }
          edges.each do |a, b|
            next unless a.is_a?(Integer) && b.is_a?(Integer)
            next if a < 0 || b < 0 || a >= nodes.size || b >= nodes.size || a == b

            adj[a][b] = true
            adj[b][a] = true
          end
          result = []
          nodes.length.times do |a|
            adj[a].each_key do |b|
              next unless b > a
              adj[b].each_key do |c|
                result << [a, b, c] if c > b && adj[a].key?(c)
              end
            end
          end
          result
        end

        def triangle_area(nodes, indices)
          a, b, c = indices.map { |index| nodes[index][:point] }
          ((b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)).abs * 0.5
        end

        def external_neighbors(triple, edges)
          members = triple.to_h { |index| [index, true] }
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

        def contraction(nodes, edges, origins, triangle, boundary, candidate, state_index)
          removed = triangle.to_h { |index| [index, true] }
          removed.delete(state_index) if state_index
          survivors = nodes.each_index.reject { |index| removed[index] }
          map = {}
          survivors.each_with_index { |previous, current| map[previous] = current }

          new_nodes = survivors.map { |index| nodes[index] }
          new_origins = survivors.map { |index| origins[index] }
          new_edges = edges.filter_map do |a, b|
            next if removed[a] || removed[b]

            [map[a], map[b]]
          end

          if state_index
            # State stays in the same position; its preexisting LOS edges are
            # already present among the filtered edges.
            return [new_nodes, new_edges, new_origins]
          end

          return nil unless candidate && candidate[:point] && candidate[:radius].to_f > 0.0

          target = new_nodes.length
          new_nodes << {point: candidate[:point], radius: candidate[:radius]}.freeze
          new_origins << nil
          boundary.each do |index|
            endpoint = map[index]
            return nil unless endpoint

            new_edges << [endpoint, target].sort
          end
          new_edges.map! { |edge| edge.sort }
          new_edges.uniq!
          [new_nodes, new_edges, new_origins]
        end

        def global_paths_preserved?(nodes, edges, origins, baseline, initial_positions)
          origins.each_with_index do |original, start_index|
            next if original.nil?

            current = shortest_distances(nodes, edges, start_index)
            before = baseline[original]
            return false unless before
            origins.each_with_index do |other, destination|
              next if other.nil? || other == original

              initial_index = initial_positions[other]
              old_length = before[initial_index]
              new_length = current[destination]
              if old_length.finite?
                return false unless new_length.finite?
                return false if new_length > old_length * MAX_GLOBAL_PATH_FACTOR + EPSILON
              end
            end
          end
          true
        end

        def shortest_distances(nodes, edges, start_index)
          neighbors = Array.new(nodes.size) { [] }
          edges.each do |first, second|
            length = distance(nodes[first][:point], nodes[second][:point])
            neighbors[first] << [second, length]
            neighbors[second] << [first, length]
          end

          result = Array.new(nodes.size, Float::INFINITY)
          visited = Array.new(nodes.size, false)
          result[start_index] = 0.0
          nodes.size.times do
            current = nil
            nodes.size.times do |i|
              if !visited[i] && (current.nil? || result[i] < result[current])
                current = i
              end
            end
            break unless current && result[current].finite?

            visited[current] = true
            neighbors[current].each do |target, weight|
              next if visited[target]

              via = result[current] + weight
              result[target] = via if via < result[target]
            end
          end
          result
        end

        def distance(a, b)
          Math.hypot(a.x - b.x, a.y - b.y)
        end
      end
    end
  end
end
