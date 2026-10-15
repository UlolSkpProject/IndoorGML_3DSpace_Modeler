# frozen_string_literal: true

require_relative 'reference_graph_contraction'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Independent OPTIMIZED pass. Does not inspect COLLAPSED certificates.
      # All topology edits and node remapping belong to the shared primitive.
      module ReferenceGraphShortcutOptimizer
        EPSILON = 1.0e-9
        SEMANTIC_ROLES = %i[door transition junction].freeze
        module_function

        def optimize(collapsed_graph, los_validator: nil)
          graph = canonical_snapshot(collapsed_graph)
          original_positions = (0...graph.fetch(:nodes).length).to_a
          removed = []
          # Remember newly validated edges by stable *input* node identities,
          # since primitive contractions reindex the current graph each time.
          new_edges_by_identity = {}
          los_cache = {}

          loop do
            nodes = graph.fetch(:nodes)
            adjacency = neighbors(nodes.length, graph.fetch(:edges))
            origins = graph.fetch(:original_indices)
            candidates = (1...nodes.length).select do |index|
              adjacency[index].length == 2 && !protected_node?(nodes[index])
            end.sort_by { |index| stable_key(index, nodes, origins) }

            changed = false
            candidates.each do |middle|
              endpoints = adjacency[middle].sort_by { |index| stable_key(index, nodes, origins) }
              representative, other = endpoints
              next unless projected_between?(nodes[representative][:point],
                                             nodes[middle][:point], nodes[other][:point])

              # Contract always verifies any NEW representative-boundary edge.
              # Existing direct edges were already Native LOS-validated.
              query = lambda do |first, last|
                key = segment_key(first, last)
                unless los_cache.key?(key)
                  los_cache[key] = begin
                    !!(los_validator && los_validator.call(first, last) == true)
                  rescue StandardError
                    false
                  end
                end
                los_cache[key]
              end
              result = ReferenceGraphContraction.contract(
                graph,
                members: [representative, middle],
                representative: representative,
                los_validator: query
              )
              next unless result[:accepted]

              removed << original_positions[middle]
              removed_set = result[:removed_indices].to_h { |index| [index, true] }
              next_positions = original_positions.each_with_index.filter_map do |identity, index|
                identity unless removed_set[index]
              end
              result[:new_edges].each do |first, last|
                ids = [next_positions.fetch(first), next_positions.fetch(last)].sort.freeze
                new_edges_by_identity[ids] = true
              end
              original_positions = next_positions
              graph = result.fetch(:graph)
              changed = true
              break # Recompute degree and indices after EVERY contraction.
            end
            break unless changed
          end

          final_id_to_index = original_positions.each_with_index.to_h
          final_edges = graph.fetch(:edges).to_h { |edge| [edge, true] }
          surviving_native_edges = new_edges_by_identity.keys.filter_map do |first, last|
            a = final_id_to_index[first]
            b = final_id_to_index[last]
            next if a.nil? || b.nil?
            edge = [a, b].sort
            edge.freeze if final_edges[edge]
          end.uniq.sort.freeze

          graph.merge(
            shortcut_removed_count: removed.length,
            shortcut_removed_indices: removed.freeze,
            shortcut_native_los_edges: surviving_native_edges
          ).freeze
        end

        # A strict interior orthogonal projection in all THREE dimensions.
        # No XY-only test and no Ruby-based approximation of Native LOS.
        def projected_between?(a, b, c)
          dx = c.x - a.x
          dy = c.y - a.y
          dz = c.z - a.z
          length_sq = dx * dx + dy * dy + dz * dz
          return false unless length_sq.finite? && length_sq > EPSILON * EPSILON

          t = ((b.x - a.x) * dx +
               (b.y - a.y) * dy +
               (b.z - a.z) * dz) / length_sq
          t.finite? && t > EPSILON && t < 1.0 - EPSILON
        end

        def stable_key(index, nodes, origins)
          origin = origins[index]
          point = nodes[index].fetch(:point)
          origin.nil? ? [1, point.x, point.y, point.z, index] : [0, origin, point.x, point.y, point.z, index]
        end

        def segment_key(first, last)
          a = [first.x, first.y, first.z].freeze
          b = [last.x, last.y, last.z].freeze
          (a <=> b).positive? ? [b, a].freeze : [a, b].freeze
        end

        def protected_node?(node)
          node[:protected] || SEMANTIC_ROLES.include?(node[:semantic_role])
        end

        def neighbors(count, edges)
          adjacency = Array.new(count) { [] }
          edges.each do |first, last|
            adjacency[first] << last
            adjacency[last] << first
          end
          adjacency.each(&:sort!)
        end

        # Complete standard Graph Snapshot even when no contraction is possible.
        # Canonicalize ordering while retaining edge metadata by original edge.
        def canonical_snapshot(source)
          raw_nodes = Array(source.fetch(:nodes))
          raw_edges = Array(source.fetch(:edges))
          origins = source.key?(:original_indices) ? Array(source[:original_indices]) : (0...raw_nodes.length).to_a
          unless origins.length == raw_nodes.length && (raw_nodes.empty? || origins.first == 0)
            raise ArgumentError, 'invalid collapsed original_indices'
          end
          unless raw_nodes.all? { |node| ReferenceGraphContraction.valid_node?(node) }
            raise ArgumentError, 'invalid collapsed nodes'
          end
          unless raw_edges.all? { |pair|
            pair.is_a?(Array) && pair.length == 2 &&
              pair.all? { |i| i.is_a?(Integer) && i.between?(0, raw_nodes.length - 1) } &&
              pair[0] != pair[1]
          }
            raise ArgumentError, 'invalid collapsed edges'
          end
          normalized = raw_edges.map(&:sort)
          raise ArgumentError, 'duplicate collapsed edge' if normalized.uniq.length != normalized.length
          order = (0...normalized.length).sort_by { |i| normalized[i] }
          graph = source.merge(
            nodes: raw_nodes.map { |node| ReferenceGraphContraction.duplicate_node(node) }.freeze,
            edges: order.map { |i| normalized[i].freeze }.freeze,
            original_indices: origins.freeze,
            merged_into: Array(source[:merged_into]).map { |entry| Array(entry).dup.freeze }.freeze,
            contraction_history: Array(source[:contraction_history]).dup.freeze
          )
          %i[edge_weights edge_metadata].each do |field|
            next unless source.key?(field)
            values = Array(source[field])
            raise ArgumentError, "invalid #{field}" unless values.length == raw_edges.length
            graph[field] = order.map { |i| values[i] }.freeze
          end
          graph.freeze
        end
      end
    end
  end
end
