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

        def restore(primal_group:, dual_group:)
          restore_cell_spaces_from_primal_group(primal_group)
          restore_states_from_dual_group(dual_group)
          restore_transitions_from_dual_group(dual_group)
        end

        private

        def restore_cell_spaces_from_primal_group(primal_group)
          return unless primal_group&.valid?

          indoor_children(primal_group.entities, 'CellSpace').each do |entity|
            cell_space = restore_cell_space(entity)
            @cell_space_registrar.call(cell_space) if cell_space
          end
        end

        def restore_states_from_dual_group(dual_group)
          return unless dual_group&.valid?

          cells_by_id = @registry.cell_spaces.each_with_object({}) { |cell_space, hash| hash[cell_space.id] = cell_space }
          indoor_children(dual_group.entities, 'State').each do |entity|
            cell_id = @serializer.attribute(entity, 'duality_cell_id')
            cell_space = cells_by_id[cell_id]
            unless cell_space
              puts "[IndoorGML] State restore skipped: missing CellSpace #{cell_id}"
              next
            end

            state = restore_state(entity, cell_space, dual_group)
            next unless state

            cell_space.restore_duality_state(state)
            @state_registrar.call(state)
          end
        end

        def restore_transitions_from_dual_group(dual_group)
          return unless dual_group&.valid?

          states_by_id = @registry.states.each_with_object({}) { |state, hash| hash[state.id] = state }
          cells_by_id = @registry.cell_spaces.each_with_object({}) { |cell_space, hash| hash[cell_space.id] = cell_space }
          indoor_children(dual_group.entities, 'Transition').each do |entity|
            state1 = states_by_id[@serializer.attribute(entity, 'state1_id')]
            state2 = states_by_id[@serializer.attribute(entity, 'state2_id')]
            unless state1 && state2
              puts '[IndoorGML] Transition restore skipped: missing State'
              next
            end

            cell1 = cells_by_id[@serializer.attribute(entity, 'cell1_id')] || state1.duality_cell
            cell2 = cells_by_id[@serializer.attribute(entity, 'cell2_id')] || state2.duality_cell
            transition = restore_transition(entity, state1, state2, cell1, cell2)
            next unless transition

            pair_key = cell_pair_key(cell1, cell2) if cell1 && cell2
            @registry.add_transition(transition, pair_key: pair_key)
            @registry.set_adjacent_pair(pair_key, cell1, cell2) if pair_key
            restore_transition_with_states(transition)
          end
        end

        def restore_cell_space(entity)
          CellSpace.restore(
            entity,
            CellSpaceType.from_label(@serializer.attribute(entity, 'cell_type')),
            id: @serializer.attribute(entity, 'id'),
            name: @serializer.attribute(entity, 'name')
          )
        rescue StandardError => e
          puts "[IndoorGML] CellSpace restore failed: #{e.class}: #{e.message}"
          nil
        end

        def restore_state(entity, cell_space, dual_group)
          State.restore(
            cell_space,
            entity,
            restored_state_position(entity, dual_group),
            id: @serializer.attribute(entity, 'id'),
            name: @serializer.attribute(entity, 'name')
          )
        rescue StandardError => e
          puts "[IndoorGML] State restore failed: #{e.class}: #{e.message}"
          nil
        end

        def restore_transition(entity, state1, state2, cell1, cell2)
          Transition.restore(
            entity,
            state1,
            state2,
            cell1: cell1,
            cell2: cell2,
            id: @serializer.attribute(entity, 'id'),
            name: @serializer.attribute(entity, 'name')
          )
        rescue StandardError => e
          puts "[IndoorGML] Transition restore failed: #{e.class}: #{e.message}"
          nil
        end

        def restored_state_position(entity, dual_group)
          x = @serializer.attribute(entity, 'position_x')
          y = @serializer.attribute(entity, 'position_y')
          z = @serializer.attribute(entity, 'position_z')
          return Geom::Point3d.new(x.to_f, y.to_f, z.to_f) unless x.nil? || y.nil? || z.nil?

          Utils::Transformation.entity_origin_in_root_local(entity, dual_group)
        end

        def indoor_children(entities, feature)
          entities.to_a.select do |entity|
            entity&.valid? && @serializer.feature(entity) == feature
          end
        end

        def restore_transition_with_states(transition)
          transition.state1.add_transition(transition)
          transition.state2.add_transition(transition)
        end

        def cell_pair_key(cell1, cell2)
          [cell1.id, cell2.id].sort.join(':')
        end
      end

    end
  end
end
