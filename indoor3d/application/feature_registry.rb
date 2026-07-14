# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class FeatureRegistry
        attr_reader :cell_spaces
        attr_reader :states
        attr_reader :transitions
        attr_reader :transitions_by_cell_pair

        def initialize
          reset!
        end

        def reset!
          @cell_spaces = []
          @states = []
          @transitions = []
          @cell_spaces_by_entity_object = {}
          @cell_spaces_by_persistent_id = {}
          @cell_spaces_by_entity_id_for_removed_callback = {}
          @adjacent_cell_space_pairs = {}
          @transitions_by_cell_pair = {}
          @adjacent_pair_keys_by_cell_id = {}
          @transition_pair_keys_by_cell_id = {}
        end

        def snapshot
          {
            cell_spaces: @cell_spaces.dup,
            states: @states.dup,
            transitions: @transitions.dup,
            cell_spaces_by_entity_object: @cell_spaces_by_entity_object.dup,
            cell_spaces_by_persistent_id: @cell_spaces_by_persistent_id.dup,
            cell_spaces_by_entity_id_for_removed_callback: @cell_spaces_by_entity_id_for_removed_callback.dup,
            adjacent_cell_space_pairs: @adjacent_cell_space_pairs.dup,
            transitions_by_cell_pair: @transitions_by_cell_pair.dup
          }
        end

        def restore!(snapshot)
          @cell_spaces = Array(snapshot[:cell_spaces]).dup
          @states = Array(snapshot[:states]).dup
          @transitions = Array(snapshot[:transitions]).dup
          @cell_spaces_by_entity_object = Hash(snapshot[:cell_spaces_by_entity_object]).dup
          @cell_spaces_by_persistent_id = Hash(snapshot[:cell_spaces_by_persistent_id]).dup
          @cell_spaces_by_entity_id_for_removed_callback = Hash(snapshot[:cell_spaces_by_entity_id_for_removed_callback]).dup
          @adjacent_cell_space_pairs = Hash(snapshot[:adjacent_cell_space_pairs]).dup
          @transitions_by_cell_pair = Hash(snapshot[:transitions_by_cell_pair]).dup
          rebuild_pair_key_indexes
        end

        def add_cell_space(cell_space)
          ensure_unique_feature_id!(cell_space)
          @cell_spaces << cell_space unless @cell_spaces.include?(cell_space)
          @cell_spaces_by_entity_object[cell_space.sketchup_group] = cell_space
          @cell_spaces_by_persistent_id[cell_space.sketchup_group.persistent_id] = cell_space
          @cell_spaces_by_entity_id_for_removed_callback[cell_space.sketchup_group.entityID] = cell_space
        end

        def remove_cell_space(cell_space)
          return if cell_space.nil?

          @cell_spaces.delete(cell_space)
          @cell_spaces_by_entity_object.delete(cell_space.sketchup_group)
          @cell_spaces_by_persistent_id.delete(cell_space.sketchup_group_id)
          @cell_spaces_by_entity_id_for_removed_callback.delete_if { |_entity_id, mapped_cell_space| mapped_cell_space == cell_space }
        end

        def find_cell_space_for_entity(entity)
          @cell_spaces_by_entity_object[entity] ||
            find_cell_space_by_persistent_id(entity.persistent_id) ||
            find_cell_space_by_removed_entity_id(entity.entityID)
        rescue StandardError
          @cell_spaces_by_entity_object[entity]
        end

        def find_cell_space_by_persistent_id(persistent_id)
          @cell_spaces_by_persistent_id[persistent_id]
        end

        def find_cell_space_by_removed_entity_id(entity_id)
          @cell_spaces_by_entity_id_for_removed_callback[entity_id]
        end

        def add_state(state)
          ensure_unique_feature_id!(state)
          @states << state unless @states.include?(state)
        end

        def remove_state(state)
          return if state.nil?

          @states.delete(state)
        end

        def add_transition(transition, pair_key: nil)
          ensure_unique_feature_id!(transition)
          @transitions << transition unless @transitions.include?(transition)
          if pair_key
            @transitions_by_cell_pair[pair_key] = transition
            index_pair_key(@transition_pair_keys_by_cell_id, pair_key)
          end
        end

        def remove_transition(transition)
          return if transition.nil?

          @transitions.delete(transition)
          @transitions_by_cell_pair.delete_if do |pair_key, mapped_transition|
            next false unless mapped_transition == transition

            unindex_pair_key(@transition_pair_keys_by_cell_id, pair_key)
            true
          end
        end

        def transition_for_pair(pair_key)
          @transitions_by_cell_pair[pair_key]
        end

        def delete_transition_for_pair(pair_key)
          transition = @transitions_by_cell_pair.delete(pair_key)
          unindex_pair_key(@transition_pair_keys_by_cell_id, pair_key) if transition
          transition
        end

        def transition_pair_keys
          @transitions_by_cell_pair.keys
        end

        def transition_pair_keys_for_cell(cell_id)
          Hash(@transition_pair_keys_by_cell_id[cell_id.to_s]).keys
        end

        def set_adjacent_pair(pair_key, cell1, cell2)
          @adjacent_cell_space_pairs[pair_key] = [cell1, cell2]
          index_pair_key(@adjacent_pair_keys_by_cell_id, pair_key)
        end

        def delete_adjacent_pair(pair_key)
          pair = @adjacent_cell_space_pairs.delete(pair_key)
          unindex_pair_key(@adjacent_pair_keys_by_cell_id, pair_key) if pair
          pair
        end

        def adjacent_pair_keys
          @adjacent_cell_space_pairs.keys
        end

        def adjacent_pair?(pair_key)
          @adjacent_cell_space_pairs.key?(pair_key)
        end

        def adjacent_pair_keys_for_cell(cell_id)
          Hash(@adjacent_pair_keys_by_cell_id[cell_id.to_s]).keys
        end

        private

        def rebuild_pair_key_indexes
          @adjacent_pair_keys_by_cell_id = {}
          @transition_pair_keys_by_cell_id = {}
          @adjacent_cell_space_pairs.each_key do |pair_key|
            index_pair_key(@adjacent_pair_keys_by_cell_id, pair_key)
          end
          @transitions_by_cell_pair.each_key do |pair_key|
            index_pair_key(@transition_pair_keys_by_cell_id, pair_key)
          end
        end

        def index_pair_key(index, pair_key)
          pair_cell_ids(pair_key).each do |cell_id|
            (index[cell_id] ||= {})[pair_key] = true
          end
        end

        def unindex_pair_key(index, pair_key)
          pair_cell_ids(pair_key).each do |cell_id|
            keys = index[cell_id]
            next unless keys

            keys.delete(pair_key)
            index.delete(cell_id) if keys.empty?
          end
        end

        def pair_cell_ids(pair_key)
          pair_key.to_s.split(':', 2)
        end

        def ensure_unique_feature_id!(feature)
          return if feature.nil?
          return unless (@cell_spaces + @states + @transitions).any? do |registered|
            !registered.equal?(feature) && registered.id.to_s == feature.id.to_s
          end

          raise ArgumentError, "Duplicate IndoorGML feature id: #{feature.id}"
        end
      end

    end
  end
end
