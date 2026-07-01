# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class RuntimeRestorer
        def initialize(registry:, serializer:, cell_space_registrar:, state_registrar:)
          @registry = registry
          @serializer = serializer
          @cell_space_registrar = cell_space_registrar
          @state_registrar = state_registrar
        end

        def restore(model:, primal_group:)
          restore_storeys_from_model(model)
          restore_cell_spaces_from_primal_group(primal_group)
          restore_states_from_cell_spaces
        end

        private

        def restore_storeys_from_model(model)
          @serializer.read_storeys(model).each do |storey|
            @registry.add_storey(storey)
          end
        end

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
          storey = @serializer.attribute(entity, 'storey')
          if storey.to_s.empty?
            legacy_storey = @registry.find_storey_by_id(@serializer.attribute(entity, 'storey_id'))
            storey = legacy_storey&.name
          end

          CellSpace.restore(
            entity,
            CellSpaceType.from_label(@serializer.attribute(entity, 'cell_type')),
            id: @serializer.attribute(entity, 'id'),
            category_code: @serializer.attribute(entity, 'category_code'),
            navigation_class: @serializer.attribute(entity, 'navigation_class'),
            navigation_class_code_space: @serializer.attribute(entity, 'navigation_class_code_space'),
            navigation_function: @serializer.attribute(entity, 'navigation_function'),
            navigation_function_code_space: @serializer.attribute(entity, 'navigation_function_code_space'),
            navigation_usage: @serializer.attribute(entity, 'navigation_usage'),
            navigation_usage_code_space: @serializer.attribute(entity, 'navigation_usage_code_space'),
            navigation_code_space: @serializer.attribute(entity, 'navigation_code_space'),
            storey: storey
          )
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] CellSpace restore failed: #{e.class}: #{e.message}"
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
          IndoorCore::Logger.puts "[IndoorGML] State restore failed: #{e.class}: #{e.message}"
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
