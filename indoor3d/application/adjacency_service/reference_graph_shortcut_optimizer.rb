# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Non-destructive post-Collapse shortcut of degree-two reference nodes.
      # A middle node is removed only if both neighbors already share a
      # validated Native LOS edge. Geometry is assessed by chord deviation
      # and path detour; inscribed circles are ONLY used by BEFORE -> AFTER.
      # No edges or point positions are invented.
      module ReferenceGraphShortcutOptimizer
        MAX_DEVIATION_CHORD_FRACTION = 0.05
        MAX_DETOUR_FACTOR = 1.05
        EPSILON = 1.0e-9

        module_function

        def optimize(graph)
          nodes = Array(graph.fetch(:nodes))
          edges = Array(graph.fetch(:edges))
          return unchanged(graph) if nodes.size < 3

          adjacency = Array.new(nodes.size) { {} }
          edges.each do |a, b|
            next unless a.is_a?(Integer) && b.is_a?(Integer)
            next if a.negative? || b.negative? || a >= nodes.size ||
                    b >= nodes.size || a == b

            adjacency[a][b] = true
            adjacency[b][a] = true
          end

          alive = Array.new(nodes.size, true)
          removed = []
          loop do
            chosen = nil
            smallest_deviation = Float::INFINITY
            (1...nodes.size).each do |middle|
              next unless alive[middle]

              neighbors = adjacency[middle].keys.select { |i| alive[i] }
              next unless neighbors.size == 2

              first, last = neighbors
              next unless adjacency[first].key?(last) # Already-validated LOS

              deviation = shortcut_deviation(nodes[first], nodes[middle], nodes[last])
              next if deviation.nil?

              if chosen.nil? || deviation < smallest_deviation - EPSILON ||
                 ((deviation - smallest_deviation).abs <= EPSILON && middle < chosen)
                chosen = middle
                smallest_deviation = deviation
              end
            end

            break if chosen.nil?

            alive[chosen] = false
            removed << chosen
          end

          return unchanged(graph) if removed.empty?

          kept = (0...nodes.size).select { |i| alive[i] }
          remap = {}
          kept.each_with_index { |old, index| remap[old] = index }
          final_edges = edges.filter_map do |a, b|
            next if remap[a].nil? || remap[b].nil?

            [remap[a], remap[b]].sort.freeze
          end.uniq.sort.freeze
          result = {
            nodes: kept.map { |i| nodes[i] }.freeze,
            edges: final_edges,
            shortcut_removed_count: removed.size,
            shortcut_removed_indices: removed.freeze
          }
          if graph.key?(:original_indices)
            origins = Array(graph[:original_indices])
            result[:original_indices] = kept.map { |i| origins[i] }.freeze
          end
          graph.merge(result).freeze
        end

        def shortcut_deviation(first, middle, last)
          a = first[:point]
          b = middle[:point]
          c = last[:point]
          dx = c.x - a.x
          dy = c.y - a.y
          length_sq = dx * dx + dy * dy
          return nil if length_sq <= EPSILON * EPSILON

          t = ((b.x - a.x) * dx + (b.y - a.y) * dy) / length_sq
          return nil unless t > EPSILON && t < 1.0 - EPSILON

          # Post-Collapse never derives a local width from an inscribed disk.
          # The normalized chord deviation and path-length detour use only
          # the three point positions, independent of node radius.
          chord = Math.sqrt(length_sq)
          deviation = Math.hypot(b.x - a.x - t * dx, b.y - a.y - t * dy)
          return nil unless deviation.finite? &&
                            deviation <= MAX_DEVIATION_CHORD_FRACTION * chord + EPSILON

          detour = Math.hypot(b.x - a.x, b.y - a.y) +
                   Math.hypot(c.x - b.x, c.y - b.y)
          return nil unless detour.finite? &&
                            detour <= MAX_DETOUR_FACTOR * chord + EPSILON

          deviation
        end

        def unchanged(graph)
          graph.merge(shortcut_removed_count: 0, shortcut_removed_indices: [].freeze).freeze
        end
      end
    end
  end
end
