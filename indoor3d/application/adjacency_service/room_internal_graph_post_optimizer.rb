# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # A second application of the same degree-two Shortcut rule AFTER
      # LOS-prioritized Kruskal connects the OPTIMIZED graph components.
      #
      # B must have precisely two neighbors, its 3D projection must lie
      # strictly inside AC, and AC must have Native LOS.
      # No circle, angle, deviation or detour threshold is introduced.
      #
      # The connected graph is not mutated. Metadata (original/clear/blocked
      # edges, edge weights and node indices) is rebuilt after contractions.
      module RoomInternalGraphPostOptimizer
        module_function

        def optimize(connected, los_batch:)
          nodes = Array(connected.fetch(:nodes))
          input_edges = Array(connected.fetch(:edges))
          original_count = Integer(connected.fetch(:original_edge_count))
          added = Array(connected.fetch(:added_edges))
          origins = Array(connected.fetch(:original_indices))
          unless nodes.length == origins.length &&
                 original_count.between?(0, input_edges.length) &&
                 added.length == input_edges.length - original_count
            raise ArgumentError, 'Invalid connected graph metadata'
          end
          raise ArgumentError, 'Native LOS batch callback required' unless los_batch.respond_to?(:call)

          adjacency = Array.new(nodes.length) { {} }
          original_edges = input_edges.first(original_count)
          input_edges.each_with_index do |pair, index|
            unless pair.is_a?(Array) && pair.length == 2 &&
                   pair.all? { |v| v.is_a?(Integer) && v >= 0 && v < nodes.length } &&
                   pair[0] < pair[1] && !adjacency[pair[0]].key?(pair[1])
              raise ArgumentError, 'Invalid or duplicate connected graph edge'
            end

            record = if index < original_count
                       { kind: :original }.freeze
                     else
                       info = added.fetch(index - original_count)
                       unless info[:edge] == pair &&
                              %i[clear blocked].include?(info[:classification]) &&
                              info[:los_clear] == (info[:classification] == :clear)
                         raise ArgumentError, 'Inconsistent Kruskal LOS classification'
                       end
                       { kind: info[:classification] }.freeze
                     end
            a, b = pair
            adjacency[a][b] = record
            adjacency[b][a] = record
          end

          alive = Array.new(nodes.length, true)
          removed = []
          los_cache = {}
          new_shortcuts = []
          checked_count = 0

          loop do
            candidates = (0...nodes.length).filter_map do |middle|
              next unless alive[middle] && adjacency[middle].length == 2

              first, last = adjacency[middle].keys.sort
              next unless ReferenceGraphShortcutOptimizer.projected_between?(
                nodes[first][:point], nodes[middle][:point], nodes[last][:point]
              )

              # A known blocked direct edge must NEVER count as verified.
              direct = adjacency[first][last]
              next if direct && direct[:kind] == :blocked

              [middle, first, last].freeze
            end
            break if candidates.empty?

            # Native LOS is queried only for the missing AC segments. Batch
            # candidates in each round to avoid repeated BVH construction per
            # candidate. Endpoint coordinates are immutable across removals.
            missing = candidates.filter_map do |_middle, first, last|
              next if adjacency[first].key?(last)

              key = [first, last].freeze
              key unless los_cache.key?(key)
            end.uniq

            missing.each_slice(RoomInternalVisibilityGraph::MAX_PAIRS_PER_BATCH) do |batch|
              segments = batch.map do |a, b|
                [nodes[a][:point], nodes[b][:point]]
              end
              results = los_batch.call(segments)
              unless results.is_a?(Array) && results.length == batch.length &&
                     results.all? { |value| value == true || value == false }
                raise ArgumentError, 'Invalid Native LOS shortcut results'
              end

              checked_count += batch.length
              batch.each_with_index { |key, i| los_cache[key] = results[i] }
            end

            selected = candidates.find do |_middle, first, last|
              direct = adjacency[first][last]
              direct ? direct[:kind] != :blocked : los_cache[[first, last]] == true
            end
            break unless selected

            middle, first, last = selected
            adjacency[first].delete(middle)
            adjacency[last].delete(middle)
            adjacency[middle].clear
            alive[middle] = false
            removed << middle

            unless adjacency[first].key?(last)
              pair = [first, last].freeze
              record = { kind: :shortcut }.freeze
              adjacency[first][last] = record
              adjacency[last][first] = record
              new_shortcuts << pair
            end
          end

          kept = (0...nodes.length).select { |index| alive[index] }
          remap = {}
          kept.each_with_index { |index, new_index| remap[index] = new_index }

          # Original edges are still placed first and retain their color.
          surviving_original = original_edges.filter_map do |a, b|
            next unless alive[a] && alive[b] && adjacency[a][b]&.dig(:kind) == :original

            [remap[a], remap[b]].freeze
          end
          surviving_added = added.filter_map do |item|
            a, b = item[:edge]
            next unless alive[a] && alive[b] &&
                        adjacency[a][b]&.dig(:kind) == item[:classification]

            [remap[a], remap[b], item[:classification], :kruskal]
          end
          surviving_shortcuts = new_shortcuts.filter_map do |a, b|
            next unless alive[a] && alive[b] && adjacency[a][b]&.dig(:kind) == :shortcut

            [remap[a], remap[b], :clear, :shortcut]
          end

          final_nodes = kept.map { |index| nodes[index] }.freeze
          final_origins = kept.map { |index| origins[index] }.freeze
          final_added = (surviving_added + surviving_shortcuts).map do |a, b, classification, source|
            edge = [a, b].freeze
            {
              edge: edge,
              length: RoomInternalVisibilityGraph.distance(
                final_nodes[a][:point], final_nodes[b][:point]
              ),
              classification: classification,
              los_clear: classification == :clear,
              source: source
            }.freeze
          end.freeze

          final_edges = (surviving_original + final_added.map { |r| r[:edge] }).freeze
          final_weights = final_edges.map do |a, b|
            RoomInternalVisibilityGraph.distance(
              final_nodes[a][:point], final_nodes[b][:point]
            )
          end.freeze

          clear_count = final_added.count { |item| item[:classification] == :clear }
          graph = connected.merge(
            nodes: final_nodes,
            original_indices: final_origins,
            edges: final_edges,
            edge_weights: final_weights,
            original_edge_count: surviving_original.length,
            added_edges: final_added,
            clear_added_count: clear_count,
            blocked_added_count: final_added.length - clear_count,
            postopt_removed_count: removed.length,
            postopt_removed_indices: removed.freeze,
            postopt_los_checked_pairs: checked_count,
            pre_postopt_node_count: nodes.length,
            pre_postopt_edge_count: input_edges.length
          ).freeze
          graph
        end
      end
    end
  end
end
