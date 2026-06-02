# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class AdjacencyService
        def initialize(registry, transition_builder:, transition_eraser:)
          @registry = registry
          @transition_builder = transition_builder
          @transition_eraser = transition_eraser
        end

        def synchronize_for(cell_space)
          return if cell_space.nil? || !cell_space.valid? || !cell_space.duality_state&.valid?

          @registry.cell_spaces.each do |other_cell_space|
            next if other_cell_space.nil? || other_cell_space == cell_space
            next unless other_cell_space.valid? && other_cell_space.duality_state&.valid?

            pair_key = cell_pair_key(cell_space, other_cell_space)
            adjacency_axis = Utils::Geometry.adjacency_axis(cell_space.sketchup_group, other_cell_space.sketchup_group)
            if transition_allowed_between?(cell_space, other_cell_space, adjacency_axis)
              @registry.set_adjacent_pair(pair_key, cell_space, other_cell_space)
              @transition_builder.call(cell_space, other_cell_space)
            else
              @transition_eraser.call(pair_key)
            end
          end
        end

        def erase_for(cell_space)
          return if cell_space.nil?

          @registry.adjacent_pair_keys.each do |pair_key|
            @transition_eraser.call(pair_key) if pair_key.split(':').include?(cell_space.id)
          end

          @registry.transition_pair_keys.each do |pair_key|
            @transition_eraser.call(pair_key) if pair_key.split(':').include?(cell_space.id)
          end
        end

        def cell_pair_key(cell1, cell2)
          [cell1.id, cell2.id].sort.join(':')
        end

        private

        def transition_allowed_between?(cell1, cell2, adjacency_axis)
          return false if adjacency_axis.nil?
          return false if cell1.cell_type == CellSpaceType::GENERAL && cell2.cell_type == CellSpaceType::GENERAL

          return adjacency_axis != :z if transition_space_pair?(cell1, cell2)

          true
        end

        def transition_space_pair?(cell1, cell2)
          cell1.cell_type == CellSpaceType::TRANSITION || cell2.cell_type == CellSpaceType::TRANSITION
        end
      end

    end
  end
end
