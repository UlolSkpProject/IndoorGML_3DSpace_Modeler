# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class RuntimeRestorer
        def initialize(registry, serializer, cell_space_registrar:, state_registrar:)
          @registry = registry
          @serializer = serializer
          @cell_space_registrar = cell_space_registrar
          @state_registrar = state_registrar
        end

        def restore(primal_group:)
          restore_cell_spaces_from_primal_group(primal_group)
          restore_states_from_cell_spaces
        end

        private

        def restore_cell_spaces_from_primal_group(primal_group)
          return unless primal_group&.valid?

          indoor_children(primal_group.entities, 'CellSpace').each do |entity|
            cell_space = restore_cell_space(entity)
            @cell_space_registrar.call(cell_space) if cell_space
          end
        end

        def restore_states_from_cell_spaces
          @registry.cell_spaces.each do |cell_space|
            state = restore_state(cell_space)
            next unless state

            cell_space.restore_duality_state(state)
            @state_registrar.call(state)
          end
        end

        def restore_cell_space(entity)
          CellSpace.restore(
            entity,
            CellSpaceType.from_label(@serializer.attribute(entity, 'cell_type')),
            id: @serializer.attribute(entity, 'id'),
            name: @serializer.attribute(entity, 'name'),
            category_code: @serializer.attribute(entity, 'category_code'),
            category_label: @serializer.attribute(entity, 'category_label'),
            category_code_space: @serializer.attribute(entity, 'category_code_space'),
            category_standard: @serializer.attribute(entity, 'category_standard')
          )
        rescue StandardError => e
          puts "[IndoorGML] CellSpace restore failed: #{e.class}: #{e.message}"
          nil
        end

        def restore_state(cell_space)
          State.restore(
            cell_space,
            nil,
            id: @serializer.attribute(cell_space.sketchup_group, 'duality_state_id'),
            name: nil
          )
        rescue StandardError => e
          puts "[IndoorGML] State restore failed: #{e.class}: #{e.message}"
          nil
        end

        def indoor_children(entities, feature)
          entities.to_a.select do |entity|
            entity&.valid? && @serializer.feature(entity) == feature
          end
        end

      end

    end
  end
end
