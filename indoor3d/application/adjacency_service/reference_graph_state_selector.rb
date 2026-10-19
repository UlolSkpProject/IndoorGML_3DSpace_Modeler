# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # State is an output of the completed OPTIMIZED graph. It never
      # participates in reference generation, contraction or optimization.
      module ReferenceGraphStateSelector
        module_function

        def select(optimized_graph)
          nodes = Array(Hash(optimized_graph).fetch(:nodes))
          raise ArgumentError, 'OPTIMIZED graph has no reference nodes' if nodes.empty?

          points = nodes.map do |node|
            point = Hash(node).fetch(:point)
            values = [point.x, point.y, point.z]
            unless values.all? { |value| value.is_a?(Numeric) && value.finite? }
              raise ArgumentError, 'OPTIMIZED graph has a non-finite reference point'
            end
            point
          rescue NoMethodError
            raise ArgumentError, 'OPTIMIZED graph has an invalid reference point'
          end

          # Online mean avoids a needlessly large intermediate sum while
          # retaining identical weight for every surviving reference node.
          mean = [0.0, 0.0, 0.0]
          points.each_with_index do |point, index|
            weight = 1.0 / (index + 1)
            mean[0] += (point.x - mean[0]) * weight
            mean[1] += (point.y - mean[1]) * weight
            mean[2] += (point.z - mean[2]) * weight
          end

          state_index = points.each_index.min_by do |index|
            point = points[index]
            dx = point.x - mean[0]
            dy = point.y - mean[1]
            dz = point.z - mean[2]
            [dx * dx + dy * dy + dz * dz, index]
          end

          {
            state_node_index: state_index,
            point: points.fetch(state_index),
            mean_point: mean.freeze
          }.freeze
        end
      end
    end
  end
end
