# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module Topology
          def update_transitions_for_state(state)
            return if state.nil?

            @transitions.each do |transition|
              next unless transition.connected_to?(state)

              update_transition(transition)
              write_transition_attributes(transition)
            end
          end

          private

          def connect_states(state1, state2)
            ensure_space_features_groups(transparent: true)

            cell1 = state1&.duality_cell
            cell2 = state2&.duality_cell
            return nil if cell1.nil? || cell2.nil?

            create_or_update_transition_for_pair(cell1, cell2)
          end

          def synchronize_adjacency_and_transitions_for_cell_space(cell_space)
            @adjacency_service.synchronize_for(cell_space)
          end

          def erase_adjacency_for_cell_space(cell_space)
            @adjacency_service.erase_for(cell_space)
          end

          def create_or_update_transition_for_pair(cell1, cell2)
            return nil if cell1.nil? || cell2.nil?
            return nil if cell1 == cell2
            return nil unless cell1.valid? && cell2.valid?
            return nil unless cell1.duality_state&.valid? && cell2.duality_state&.valid?

            pair_key = cell_pair_key(cell1, cell2)
            transition = @feature_registry.transition_for_pair(pair_key)
            unless transition&.valid?
              transition = Transition.new(
                cell1.duality_state,
                cell2.duality_state,
                nil,
                cell1: cell1,
                cell2: cell2
              )
              @feature_registry.add_transition(transition, pair_key: pair_key)
            end

            return nil unless update_transition(transition)

            register_transition_with_states(transition)
            write_transition_attributes(transition)
            transition
          end

          def erase_transition_for_pair_key(pair_key)
            transition = @feature_registry.delete_transition_for_pair(pair_key)
            return if transition.nil?

            erase_transition(transition)
            @feature_registry.delete_adjacent_pair(pair_key)
          end

          def erase_transition(transition)
            return if transition.nil?

            unregister_transition_from_states(transition)
            transition.erase!
            @feature_registry.remove_transition(transition)
          end

          def cell_pair_key(cell1, cell2)
            @adjacency_service.cell_pair_key(cell1, cell2)
          end

          def register_transition_with_states(transition)
            transition.state1.add_transition(transition)
            transition.state2.add_transition(transition)
            write_state_attributes(transition.state1)
            write_state_attributes(transition.state2)
          end

          def unregister_transition_from_states(transition)
            transition.state1.remove_transition(transition) if transition.state1
            transition.state2.remove_transition(transition) if transition.state2
            write_state_attributes(transition.state1) if transition.state1&.valid?
            write_state_attributes(transition.state2) if transition.state2&.valid?
          end

          def erase_transitions_for_state(state)
            return if state.nil?

            @transitions.select { |transition| transition.connected_to?(state) }.each do |transition|
              if transition.cell1 && transition.cell2
                pair_key = cell_pair_key(transition.cell1, transition.cell2)
                @feature_registry.delete_transition_for_pair(pair_key)
                @feature_registry.delete_adjacent_pair(pair_key)
              end
              erase_transition(transition)
            end
          end

          def update_transition(transition)
            transition.update(
              state_local_position(transition.state1),
              state_local_position(transition.state2)
            )
          end

          def rebuild_runtime_transitions_from_cell_adjacency
            @cell_spaces.each do |cell_space|
              synchronize_adjacency_and_transitions_for_cell_space(cell_space)
            end
          end
        end
      end
    end
  end
end
