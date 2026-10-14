# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Non-destructive reduction of the V5 Room visibility graph.
      #
      # A native Edge already means overlapping XY disks AND unobstructed LOS.
      # We only remove a node if a larger, directly visible disk covers its
      # center, all its currently surviving neighbors can see the same
      # representative, and the local detour is acceptably short.
      #
      # Original nodes and edges are NEVER mutated. State (node zero) and
      # dead-end / isolated nodes are protected. No synthetic LOS edges are
      # created, so the reduced graph cannot acquire a wall-crossing edge.
      module ReferenceGraphSimplifier
        MAX_LOCAL_DETOUR_FACTOR = 1.25
        EPSILON = 1.0e-9

        module_function

        def simplify(source)
          nodes = Array(source.fetch(:nodes))
          edges = Array(source.fetch(:edges))
          size = nodes.length
          return snapshot(nodes, edges, (0...size).to_a, []) if size <= 2

          neighbors = Array.new(size) { [] }
          edges.each do |first, second|
            next unless first.is_a?(Integer) && second.is_a?(Integer)
            next unless first >= 0 && first < second && second < size

            neighbors[first] << second
            neighbors[second] << first
          end
          neighbors.each(&:freeze)

          alive = Array.new(size, true)
          absorbed = []
          # Small disks are considered first; State remains non-removable.
          candidates = (1...size).sort_by do |index|
            [radius(nodes[index]), index]
          end

          candidates.each do |index|
            next unless alive[index]

            connected = neighbors[index].select { |other| alive[other] }
            # Preserve graph endpoints, unsupported branches, and islands.
            next if connected.length < 2

            candidate = nodes[index]
            candidate_radius = radius(candidate)
            candidate_center = candidate[:point]

            targets = connected.select do |other|
              target_radius = radius(nodes[other])
              next false if target_radius + EPSILON < candidate_radius
              next false if other > 0 &&
                            (target_radius - candidate_radius).abs <= EPSILON &&
                            other > index

              distance(candidate_center, nodes[other][:point]) <= target_radius + EPSILON
            end.sort_by { |other| [-radius(nodes[other]), other.zero? ? -1 : other] }

            targets.each do |target|
              other_neighbors = connected.reject { |index2| index2 == target }
              next if other_neighbors.empty?

              # All affected original graph links must be replaced by
              # already validated Native LOS edges (no invented shortcuts).
              next unless other_neighbors.all? { |other| neighbors[target].include?(other) }

              safe_detours = other_neighbors.combination(2).all? do |first, second|
                # If the original graph already had a direct link, it
                # survives unchanged and does not need a detour.
                next true if neighbors[first].include?(second)

                before = distance(nodes[first][:point], candidate_center) +
                         distance(candidate_center, nodes[second][:point])
                after = distance(nodes[first][:point], nodes[target][:point]) +
                        distance(nodes[target][:point], nodes[second][:point])
                after <= MAX_LOCAL_DETOUR_FACTOR * before + EPSILON
              end
              next unless safe_detours

              alive[index] = false
              absorbed << [index, target]
              break
            end
          end

          kept = (0...size).select { |index| alive[index] }
          snapshot(nodes, edges, kept, absorbed)
        end

        def distance(first, second)
          Math.hypot(first.x - second.x, first.y - second.y)
        end

        def radius(node)
          node[:radius].to_f
        end

        def snapshot(nodes, edges, kept, absorbed)
          reindex = {}
          kept.each_with_index { |old_index, new_index| reindex[old_index] = new_index }

          result_nodes = kept.map { |index| nodes[index] }.freeze
          result_edges = edges.filter_map do |first, second|
            first_new = reindex[first]
            second_new = reindex[second]
            next if first_new.nil? || second_new.nil?

            [first_new, second_new].freeze
          end.freeze

          # Resolve intermediate representatives when a larger disk later
          # absorbs a representative from an earlier step.
          parents = absorbed.to_h
          merged_into = absorbed.map do |from, target|
            target = parents.fetch(target, target) while parents.key?(target)
            [from, target].freeze
          end.freeze

          {
            nodes: result_nodes,
            edges: result_edges,
            original_indices: kept.freeze,
            merged_into: merged_into
          }.freeze
        end
      end
    end
  end
end
