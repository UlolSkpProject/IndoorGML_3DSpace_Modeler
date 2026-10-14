# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Deferred, non-destructive contraction of triangular cycles in the
      # AFTER graph. All triangles are detected and evaluated against the SAME
      # original After snapshot; only then is a single batch graph constructed.
      #
      # Native V6 prevalidates centroid positions and LOS to original nodes.
      # A replacement never gains an invented LOS edge. Overlapping cycles,
      # or cycles joined by an edge between nodes both being removed, are
      # conflicting and cannot be contracted in the same batch.
      #
      # State is immutable. No shortest-path/detour increase limit is imposed.
      # BEFORE and AFTER graphs are not mutated by this diagnostic stage.
      module ReferenceGraphLoopCollapser
        MAX_GRAPH_NODES = 192
        MAX_COLLAPSES = 256

        module_function

        def collapse(after_graph, verified_candidates)
          nodes = Array(after_graph.fetch(:nodes))
          edges = Array(after_graph.fetch(:edges))
          origins = Array(after_graph.fetch(:original_indices))

          return unchanged(after_graph) if nodes.length > MAX_GRAPH_NODES ||
                                           nodes.length != origins.length ||
                                           origins.first != 0

          triangles = cycle_triangles(nodes, edges)
          return unchanged(after_graph, triangles.length) if triangles.empty?

          candidates = Array(verified_candidates).each_with_object({}) do |record, lookup|
            triple = Array(record[:triangle]).sort
            lookup[triple] = record if triple.length == 3 && triple.uniq.length == 3
          end

          # Freeze the detection snapshot logically: both eligibility and
          # conflict resolution use the original AFTER nodes and edges only.
          # Smaller triangles have priority, with deterministic index ties.
          triangles.sort_by! { |triple| [triangle_area(nodes, triple), triple] }
          eligible = triangles.filter_map do |triple|
            original_ids = triple.map { |index| origins[index] }
            next if original_ids.any?(&:nil?)

            state_loop = original_ids.include?(0)
            candidate = state_loop ? nil : candidates[original_ids.sort]
            next unless state_loop || candidate

            boundary = external_neighbors(triple, edges)
            next if boundary.any? { |index| origins[index].nil? }

            if state_loop
              # Native's existing State edges must already reach ALL external
              # neighbors. State itself is retained, not regenerated.
              next unless boundary.all? { |index| edge_exists?(edges, 0, index) }
              removed = triple.reject(&:zero?)
            else
              # Every external replacement edge was validated by Native LOS,
              # without a circle-overlap requirement.
              next unless candidate[:point] && candidate[:radius].to_f.positive?
              visible = Array(candidate[:visible_neighbors])
              next unless boundary.all? { |index| visible.include?(origins[index]) }
              removed = triple
            end

            {
              triangle: triple.freeze,
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

            # A node cannot belong to two contracts; even shared State
            # triangles are deferred to later experiments, not merged twice.
            next if option[:triangle].any? { |index| reserved_vertices[index] }

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
            option[:triangle].each { |index| reserved_vertices[index] = true }
          end

          return unchanged(after_graph, triangles.length, eligible.length) if selected.empty?

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
            triangle_count: triangles.length,
            eligible_count: eligible.length,
            merged_into: Array(after_graph[:merged_into])
          }.freeze
        end

        def unchanged(after_graph, triangles = 0, eligible = 0)
          after_graph.merge(
            collapse_count: 0,
            triangle_count: triangles,
            eligible_count: eligible
          ).freeze
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
          ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)).abs * 0.5
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
      end
    end
  end
end
