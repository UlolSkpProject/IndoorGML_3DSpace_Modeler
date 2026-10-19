# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Runtime-only routing on OPTIMIZED / Room connected reference graphs.
      # Blocked diagnostic edges are never traversed.
      module ReferenceGraphTransitionRouter
        module_function

        # Returns State reference node -> reachable gateway reference node,
        # inclusive, or nil when the snapshot cannot supply a safe graph route.
        def route(graph, state_node_index, waypoint)
          return nil unless graph.is_a?(Hash) && valid_point?(waypoint)

          nodes = Array(graph[:nodes])
          return nil if nodes.empty? || !state_node_index.is_a?(Integer) ||
                        !state_node_index.between?(0, nodes.length - 1)

          points = nodes.map { |node| node.is_a?(Hash) ? node[:point] : nil }
          return nil unless points.all? { |point| valid_point?(point) }

          adjacency = navigable_adjacency(graph, points)
          return nil unless adjacency

          distances, previous = shortest_paths(adjacency, state_node_index)
          gateway = (0...points.length).select { |index| distances[index].finite? }.min_by do |index|
            point = points[index]
            delta_x = point.x - waypoint.x
            delta_y = point.y - waypoint.y
            delta_z = point.z - waypoint.z
            [delta_x * delta_x + delta_y * delta_y + delta_z * delta_z, index]
          end
          return nil unless gateway

          indices = route_indices(gateway, previous, state_node_index)
          return nil unless indices

          indices.map { |index| points[index] }
        rescue StandardError
          nil
        end

        def navigable_adjacency(graph, points)
          edges = Array(graph[:edges])
          weights = graph.key?(:edge_weights) ? Array(graph[:edge_weights]) : nil
          metadata = graph.key?(:edge_metadata) ? Array(graph[:edge_metadata]) : nil
          return nil if weights && weights.length != edges.length
          return nil if metadata && metadata.length != edges.length

          original_count = graph[:original_edge_count]
          added = Array(graph[:added_edges])
          if graph.key?(:original_edge_count) || graph.key?(:added_edges)
            return nil unless original_count.is_a?(Integer) &&
                              original_count.between?(0, edges.length) &&
                              added.length == edges.length - original_count
          end

          adjacency = Array.new(points.length) { [] }
          edges.each_with_index do |edge, index|
            next unless edge.is_a?(Array) && edge.length == 2

            a, b = edge
            next unless a.is_a?(Integer) && b.is_a?(Integer) && a != b &&
                        a.between?(0, points.length - 1) && b.between?(0, points.length - 1)

            if original_count && index >= original_count
              annotation = added[index - original_count]
              next unless annotation.is_a?(Hash) && annotation[:edge] == edge &&
                          annotation[:classification] == :clear && annotation[:los_clear] == true
            end

            annotation = metadata && metadata[index]
            next if annotation.is_a?(Hash) &&
                    (annotation[:classification] == :blocked || annotation[:los_clear] == false)
            # An explicit classification must never silently become a normal edge.
            next if annotation.is_a?(Hash) && annotation.key?(:classification) &&
                    annotation[:classification] != :clear

            weight = weights && weights[index]
            # Negative/non-finite numeric weights are rejected, not converted
            # into cheaper Euclidean edges. Missing/non-numeric ones use distance.
            next if weight.is_a?(Numeric) && (!weight.finite? || weight.negative?)
            weight = euclidean_distance(points[a], points[b]) unless weight.is_a?(Numeric)
            next unless weight.finite? && weight >= 0

            adjacency[a] << [b, weight]
            adjacency[b] << [a, weight]
          end
          adjacency.each { |neighbors| neighbors.sort_by!(&:first) }
          adjacency
        end

        def shortest_paths(adjacency, start)
          distances = Array.new(adjacency.length, Float::INFINITY)
          previous = Array.new(adjacency.length)
          settled = Array.new(adjacency.length, false)
          heap = []
          distances[start] = 0.0
          heap_push(heap, [0.0, start])

          until heap.empty?
            distance, current = heap_pop(heap)
            next if settled[current] || distance != distances[current]

            settled[current] = true
            adjacency[current].each do |neighbor, weight|
              next if settled[neighbor]

              candidate = distance + weight
              next unless candidate.finite?

              if candidate < distances[neighbor] ||
                 (candidate == distances[neighbor] &&
                  preferable_equal_cost_path?(current, neighbor, previous, start))
                distances[neighbor] = candidate
                previous[neighbor] = current
                heap_push(heap, [candidate, neighbor])
              end
            end
          end
          [distances, previous]
        end

        # Compare entire node-index sequences only on actual cost ties.
        # Avoid allocating an O(N)-length path for every Dijkstra visit.
        def preferable_equal_cost_path?(parent, neighbor, previous, start)
          prefix = route_indices(parent, previous, start)
          existing = route_indices(neighbor, previous, start)
          return false unless prefix
          return true unless existing

          (prefix.push(neighbor) <=> existing).negative?
        end

        def route_indices(target, previous, start)
          indices = []
          current = target
          previous.length.times do
            return nil unless current.is_a?(Integer) &&
                              current.between?(0, previous.length - 1)

            indices << current
            return indices.reverse if current == start

            current = previous[current]
          end
          nil
        end

        def heap_push(heap, entry)
          index = heap.length
          heap << entry
          while index.positive?
            parent = (index - 1) / 2
            break unless (entry <=> heap[parent]).negative?

            heap[index] = heap[parent]
            index = parent
          end
          heap[index] = entry
        end

        def heap_pop(heap)
          first = heap.first
          last = heap.pop
          return first if heap.empty?

          index = 0
          while (child = index * 2 + 1) < heap.length
            right = child + 1
            child = right if right < heap.length && (heap[right] <=> heap[child]).negative?
            break unless (heap[child] <=> last).negative?

            heap[index] = heap[child]
            index = child
          end
          heap[index] = last
          first
        end

        def euclidean_distance(a, b)
          Math.sqrt((a.x - b.x)**2 + (a.y - b.y)**2 + (a.z - b.z)**2)
        end

        def valid_point?(point)
          point && %i[x y z].all? { |axis|
            value = point.public_send(axis)
            value.is_a?(Numeric) && value.finite?
          }
        rescue NoMethodError
          false
        end
      end
    end
  end
end
