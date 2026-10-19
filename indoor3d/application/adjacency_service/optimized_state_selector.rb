# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Select the final State node AFTER the OPTIMIZED stage, without
      # reordering graph vertices. Native node 0 is a provisional seed and is
      # not an eligible reference point when any optimized reference survives.
      module OptimizedStateSelector
        module_function

        def select(graph, bounds:)
          nodes = Array(Hash(graph)[:nodes])
          return nil if nodes.size < 2

          minimum = Array(Hash(bounds)[:min])
          maximum = Array(Hash(bounds)[:max])
          return nil unless minimum.size == 3 && maximum.size == 3

          values = (minimum + maximum).map { |coordinate| Float(coordinate) }
          return nil unless values.all?(&:finite?)
          return nil unless 3.times.all? { |axis| values[axis] <= values[axis + 3] }

          center = 3.times.map { |axis| (values[axis] + values[axis + 3]) * 0.5 }
          candidates = (1...nodes.size).filter_map do |index|
            point = Hash(nodes[index])[:point]
            next unless point && %i[x y z].all? { |axis| point.respond_to?(axis) }
            coords = [point.x, point.y, point.z]
            next unless coords.all? { |value| value.is_a?(Numeric) && value.finite? }

            distance_squared = coords.each_index.sum do |axis|
              difference = coords[axis] - center[axis]
              difference * difference
            end
            next unless distance_squared.finite?

            [distance_squared, index]
          end
          return nil if candidates.empty?

          _distance_squared, selected_index = candidates.min
          point = nodes[selected_index][:point]
          snapshot = graph.merge(
            state_node_index: selected_index,
            state_selection: :aabb_nearest_optimized_reference
          ).freeze
          { graph: snapshot, index: selected_index,
            coordinates: [point.x, point.y, point.z].freeze }.freeze
        rescue ArgumentError, TypeError, KeyError
          nil
        end
      end
    end
  end
end
