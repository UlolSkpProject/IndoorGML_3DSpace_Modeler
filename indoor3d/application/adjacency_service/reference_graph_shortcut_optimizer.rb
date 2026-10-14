# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Experimental, non-destructive post-Collapse shortcut reduction.
      # Only immutable State, degree-two nodes, and orthogonal projection
      # onto the neighbor segment are geometric eligibility conditions.
      #
      # A missing direct A-C edge MUST pass Native Room LOS before it can
      # be introduced. Existing A-C edges already passed Native LOS.
      # No inscribed circle, deviation threshold, or detour cap is used.
      # The original BEFORE / AFTER / COLLAPSED snapshots are untouched.
      module ReferenceGraphShortcutOptimizer
        EPSILON = 1.0e-9

        module_function

        # los_validator receives two root-local Point3d objects and must
        # return true ONLY for a verified clear segment in the same Room.
        # With no validator, a missing direct edge is never synthesized.
        def optimize(graph, los_validator: nil)
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
          validated_new_edges = {}
          failed_los = {}

          # Reevaluate connectivity after every accepted contraction.
          loop do
            chosen = nil
            validated_new_edge = nil

            (1...nodes.size).each do |middle|
              next unless alive[middle]
              neighbors = adjacency[middle].keys.sort
              next unless neighbors.size == 2

              first, last = neighbors
              next unless projected_between?(
                nodes[first][:point], nodes[middle][:point], nodes[last][:point]
              )

              # No pre-existing Edge is REQUIRED, but a new one is allowed
              # only after Native checks the geometry without circle overlap.
              if !adjacency[first].key?(last)
                segment_key = [first, last].sort.freeze
                next if failed_los[segment_key]
                next unless los_validator
                unless los_validator.call(
                  nodes[first][:point], nodes[last][:point]
                ) == true
                  failed_los[segment_key] = true
                  next
                end

                validated_new_edge = segment_key
              else
                validated_new_edge = nil
              end

              chosen = [middle, first, last]
              break
            end

            break unless chosen

            middle, first, last = chosen
            adjacency[first].delete(middle)
            adjacency[last].delete(middle)

            if validated_new_edge
              adjacency[first][last] = true
              adjacency[last][first] = true
              validated_new_edges[validated_new_edge] = true
            end

            adjacency[middle].clear
            alive[middle] = false
            removed << middle
          end

          return unchanged(graph) if removed.empty?

          kept = (0...nodes.size).select { |i| alive[i] }
          remap = {}
          kept.each_with_index { |old, current| remap[old] = current }

          final_edges = kept.flat_map do |index|
            adjacency[index].keys.filter_map do |neighbor|
              next unless alive[neighbor] && index < neighbor

              [remap[index], remap[neighbor]].freeze
            end
          end.sort.freeze
          new_edges = validated_new_edges.keys.filter_map do |a, b|
            next unless alive[a] && alive[b] && adjacency[a].key?(b)

            [remap[a], remap[b]].freeze
          end.sort.freeze

          result = {
            nodes: kept.map { |index| nodes[index] }.freeze,
            edges: final_edges,
            shortcut_removed_count: removed.size,
            shortcut_removed_indices: removed.freeze,
            shortcut_native_los_edges: new_edges
          }
          if graph.key?(:original_indices)
            origins = Array(graph[:original_indices])
            result[:original_indices] = kept.map { |index| origins[index] }.freeze
          end
          graph.merge(result).freeze
        end

        # No deviation or detour threshold: only a strict interior projection.
        def projected_between?(a, b, c)
          dx = c.x - a.x
          dy = c.y - a.y
          length_sq = dx * dx + dy * dy
          return false unless length_sq.finite? && length_sq > EPSILON * EPSILON

          t = ((b.x - a.x) * dx + (b.y - a.y) * dy) / length_sq
          t.finite? && t > EPSILON && t < 1.0 - EPSILON
        end

        def unchanged(graph)
          graph.merge(
            shortcut_removed_count: 0,
            shortcut_removed_indices: [].freeze,
            shortcut_native_los_edges: [].freeze
          ).freeze
        end
      end
    end
  end
end
