# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Per-Room, runtime-only visibility graph over the final OPTIMIZED
      # State (node 0) and surviving Reference Points. Every graph edge is
      # independently validated by Native geometry LOS, irrespective of
      # inscribed-circle overlap or the edges of preceding debug stages.
      #
      # The Native session is available only during State generation.
      # Build once there; never perform LOS checks in a SketchUp overlay.
      module RoomInternalVisibilityGraph
        MAX_NODES = 192
        MAX_PAIRS_PER_BATCH = 2048

        module_function

        def build(optimized, los_batch:)
          nodes = Array(optimized.fetch(:nodes))
          unless nodes.length.between?(1, MAX_NODES)
            raise ArgumentError,
                  "Room internal graph requires 1..#{MAX_NODES} nodes; got #{nodes.length}"
          end
          origins = Array(optimized.fetch(:original_indices))
          unless origins.size == nodes.size && origins.first == 0
            raise ArgumentError, 'Room visibility graph must have State at node 0'
          end
          unless los_batch.respond_to?(:call)
            raise ArgumentError, 'Native LOS batch callback required'
          end

          # All nodes and original indices are immutable snapshots. State
          # always remains node zero; no new or shifted points are created.
          edges = []
          weights = []
          pending = []

          flush = lambda do
            return if pending.empty?

            pairs = pending.map { |_a, _b, first, last| [first, last] }
            results = Array(los_batch.call(pairs))
            unless results.length == pending.length &&
                   results.all? { |value| value == true || value == false }
              raise ArgumentError, 'Native LOS batch returned invalid results'
            end

            pending.each_with_index do |(a, b, first, last), index|
              next unless results[index]

              edges << [a, b].freeze
              weights << Math.sqrt(
                (first.x - last.x)**2 +
                (first.y - last.y)**2 +
                (first.z - last.z)**2
              )
            end
            pending.clear
          end

          nodes.each_with_index do |node, first_index|
            first = node.fetch(:point)
            unless [first.x, first.y, first.z].all?(&:finite?)
              raise ArgumentError, 'Room visibility graph has non-finite node position'
            end
            ((first_index + 1)...nodes.length).each do |second_index|
              last = nodes[second_index].fetch(:point)
              pending << [first_index, second_index, first, last]
              flush.call if pending.size == MAX_PAIRS_PER_BATCH
            end
          end
          flush.call

          # Edge weights use the same distance units as SketchUp's native
          # geometry coordinates. Each weight corresponds to edges[index].
          {
            nodes: nodes.freeze,
            edges: edges.freeze,
            edge_weights: weights.freeze,
            original_indices: origins.freeze,
            source_stage: :optimized,
            checked_pairs: nodes.size * (nodes.size - 1) / 2,
            visible_pairs: edges.length
          }.freeze
        end
      end
    end
  end
end
