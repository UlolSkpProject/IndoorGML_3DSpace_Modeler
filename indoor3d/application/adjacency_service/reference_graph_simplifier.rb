# frozen_string_literal: true

require_relative 'reference_graph_contraction'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Certified-loop-aware compact cluster contraction for AFTER.
      # BEFORE and its Native certificate records stay unchanged.
      module ReferenceGraphSimplifier
        EPSILON = 1.0e-9
        MAX_CLUSTER_DIAMETER_FACTOR = 1.6
        MAX_CLUSTER_SIZE = 8

        module_function

        # los_batch: Native ->( [[Point3d,Point3d], ...] ) { [true/false,...] }
        # Without an open Native session, only already validated graph
        # edges are allowed to replace external connections.
        def simplify(source, protected_indices: [], los_batch: nil)
          initial_nodes = Array(source.fetch(:nodes))
          initial_edges = Array(source.fetch(:edges))
          originals = Array(source[:original_indices] || (0...initial_nodes.size).to_a)
          raise ArgumentError, 'invalid source indices' unless originals.length == initial_nodes.length &&
                                                               (originals.empty? || originals.first == 0)

          protected = protected_originals(source, protected_indices)
          graph = source.merge(
            original_indices: originals.freeze,
            merged_into: Array(source[:merged_into]).freeze
          ).freeze
          # Existing State and large spheres are preferred, then original id.
          order = (0...initial_nodes.size).sort_by do |i|
            [-radius(initial_nodes[i]), originals[i] || i, i]
          end

          order.each do |original_index|
            current_origins = graph.fetch(:original_indices)
            center = current_origins.index(originals[original_index])
            next unless center
            nodes = graph.fetch(:nodes)
            adjacency = neighbors(nodes.length, graph.fetch(:edges))
            next if !center.zero? && protected.include?(current_origins[center])

            members = [center]
            adjacent = adjacency[center].sort_by { |i| [radius(nodes[i]), current_origins[i] || i] }
            adjacent.each do |index|
              next if members.length >= MAX_CLUSTER_SIZE
              next if index.zero? || protected.include?(current_origins[index])
              next if adjacency[index].length < 2
              # Degree-2 chain nodes no longer need a common neighbor.
              # Preserve meaningful articulation junctions (degree >= 3).
              next if meaningful_branch?(index, adjacency)
              next if radius(nodes[index]) > radius(nodes[center]) + EPSILON
              d = distance(nodes[center][:point], nodes[index][:point])
              # Strict distance to the larger wall-clearance radius.
              next unless d < [radius(nodes[center]), radius(nodes[index])].max
              next unless (members + [index]).combination(2).all? do |a, b|
                distance(nodes[a][:point], nodes[b][:point]) <=
                  MAX_CLUSTER_DIAMETER_FACTOR *
                    [radius(nodes[a]), radius(nodes[b])].min + EPSILON
              end
              members << index
            end
            next if members.length < 2
            # Retain at least one non-State reference from a component.
            if center.zero? && members.length == nodes.length
              members.pop
            end
            next if members.length < 2
            # Attempt the largest compact cluster first, then shrink
            # deterministically if one external gateway cannot be replaced.
            while members.length > 1
              checks = prepare_los(members, center, nodes, adjacency, los_batch)
              if checks
                attempt = ReferenceGraphContraction.contract(
                  graph,
                  members: members,
                  representative: center,
                  protected_indices: current_origins.each_with_index.filter_map do |id, i|
                    i if protected.include?(id)
                  end,
                  los_validator: checks
                )
                if attempt[:accepted]
                  graph = attempt[:graph]
                  break
                end
              end
              members.pop
            end
          end
          graph
        end

        def protected_originals(source, explicit)
          nodes = Array(source.fetch(:nodes))
          adjacency = neighbors(nodes.size, Array(source.fetch(:edges)))
          protected = Array(explicit).select { |i| i.is_a?(Integer) && i.between?(0, nodes.size - 1) }
          protected << 0 unless nodes.empty?
          nodes.each_with_index do |node, index|
            protected << index if node[:protected] ||
                                  %i[door transition junction].include?(node[:semantic_role])
          end
          # Certificates are Native-issued against the original BEFORE graph.
          # Protect ring AND its current external gateways so the certificate
          # is not silently invalidated before COLLAPSED.
          Array(source[:loop_candidates]).each do |record|
            vertices = Array(record[:vertices] || record[:triangle])
            next unless vertices.length.between?(3, 32) &&
                        vertices.uniq.length == vertices.length &&
                        vertices.all? { |i| i.is_a?(Integer) && i.between?(0, nodes.size - 1) }
            protected.concat(vertices)
            member_set = vertices.to_h { |i| [i, true] }
            vertices.each do |index|
              adjacency[index].each { |neighbor| protected << neighbor unless member_set[neighbor] }
            end
          end
          origins = Array(source[:original_indices] || (0...nodes.size).to_a)
          protected.map { |i| origins[i] }.compact.uniq.freeze
        end

        # Protect genuine articulation junctions even if a native shortcut
        # might be available. Non-articulation dense junctions can be reduced.
        def meaningful_branch?(index, adjacency)
          connected = adjacency[index]
          return false if connected.length <= 2
          reached = { connected.first => true }
          queue = [connected.first]
          head = 0
          while head < queue.length
            current = queue[head]
            head += 1
            adjacency[current].each do |other|
              next if other == index || reached[other]
              reached[other] = true
              queue << other
            end
          end
          connected.any? { |other| !reached[other] }
        end

        # Diagnostic helper only; not a prerequisite for AFTER contraction.
        def common_neighbor?(a, b, adjacency)
          adjacency[a].any? { |index| index != b && adjacency[b].include?(index) }
        end

        def neighbors(count, edges)
          result = Array.new(count) { [] }
          Array(edges).each do |a, b|
            next unless a.is_a?(Integer) && b.is_a?(Integer) &&
                        a.between?(0, count - 1) && b.between?(0, count - 1) && a != b
            result[a] << b
            result[b] << a
          end
          result.each { |v| v.uniq!; v.sort! }
          result
        end

        def prepare_los(members, representative, nodes, adjacency, los_batch)
          target = (members.reject { |i| i == representative } +
                    members.flat_map { |i| adjacency[i] }.reject { |i| members.include?(i) }).uniq.sort
          required = target.reject { |i| adjacency[representative].include?(i) }
          return nil if required.any? && !los_batch
          return nil unless los_batch || required.empty?
          pairs = required.map { |i| [nodes[representative][:point], nodes[i][:point]] }
          results = pairs.empty? ? [] : Array(los_batch.call(pairs))
          return nil unless results.length == pairs.length &&
                            results.all? { |v| v == true }
          # Every missing edge has been checked in one Native LOS batch.
          ->(_first, _last) { true }
        rescue StandardError
          nil
        end

        def distance(a, b)
          Math.sqrt((a.x - b.x)**2 + (a.y - b.y)**2 + (a.z - b.z)**2)
        end

        def radius(node)
          node[:radius].to_f
        end
      end
    end
  end
end
