# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class IndoorModel
        PRIMAL_GROUP_NAME = 'IndoorGML_PrimalSpaceFeatures'
        DUAL_GROUP_NAME = 'IndoorGML_DualSpaceFeatures'
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml'
        INDOOR_GML_VERSION = '1.1'

        attr_reader :cell_spaces
        attr_reader :states
        attr_reader :transitions
        attr_reader :primal_group
        attr_reader :dual_group

        def self.current
          @current ||= new
        end

        def initialize
          @cell_spaces = []
          @states = []
          @transitions = []
          @cell_spaces_by_entity = {}
          @cell_spaces_by_entity_id = {}
          @states_by_entity = {}
          @states_by_entity_id = {}
          @adjacent_cell_space_pairs = {}
          @transitions_by_cell_pair = {}
          @cell_space_observer = CellSpaceObserver.new(self)
          @state_observer = StateObserver.new(self)
          @space_features_observer = SpaceFeaturesObserver.new(self)
          @space_features_observed_ids = {}
          @space_features_expected_names = {}
          @space_features_last_transforms = {}
          @syncing = false
          @erasing = false
          @constraining_space_features = false
          @primal_group = nil
          @dual_group = nil
        end

        def convert_group_to_cell_space(sketchup_group, cell_type = CellSpaceType::GENERAL)
          raise ArgumentError, 'Group is already converted to CellSpace' if converted_group?(sketchup_group)

          ensure_space_features_groups
          cell_group = place_cell_group(sketchup_group)
          cell_space = CellSpace.new(cell_group, cell_type)
          name_cell_space_entity(cell_space)
          apply_cell_space_material(cell_space)
          state = cell_space.create_duality_state(@dual_group.entities, cell_space_local_origin(cell_space))

          register_cell_space(cell_space)
          register_state(state)
          write_attributes(cell_space)
          synchronize_adjacency_and_transitions_for_cell_space(cell_space)

          cell_space
        end

        def change_cell_space_type(sketchup_group, cell_type)
          cell_space = find_cell_space_for_entity(sketchup_group)
          raise ArgumentError, 'Selected entity is not a registered CellSpace' if cell_space.nil?
          raise ArgumentError, 'CellSpace is no longer valid' unless cell_space.valid?

          sync do
            cell_space.cell_type = cell_type
            name_cell_space_entity(cell_space)
            apply_cell_space_material(cell_space)
            write_cell_space_attributes(cell_space)
            synchronize_adjacency_and_transitions_for_cell_space(cell_space)
          end

          cell_space
        end

        def cell_space_changed(entity)
          return if @syncing || @erasing

          cell_space = find_cell_space_for_entity(entity)
          return if cell_space.nil? || !cell_space.valid?

          sync do
            state = cell_space.duality_state
            if state&.valid?
              local_position = cell_space_local_origin(cell_space)
              move_state_to_local_position(state, local_position)
            end
            synchronize_adjacency_and_transitions_for_cell_space(cell_space)
          end
        end

        def state_changed(entity)
          return if @syncing || @erasing

          state = find_state_for_entity(entity)
          return if state.nil? || !state.valid?

          sync do
            cell_space = state.duality_cell
            local_position = state_local_position(state)
            update_state_position(state, local_position)
            move_cell_space_to_local_position(cell_space, local_position) if cell_space&.valid?
            synchronize_adjacency_and_transitions_for_cell_space(cell_space) if cell_space&.valid?
          end
        end

        def cell_space_erased(entity)
          return if @erasing

          cell_space = find_cell_space_for_entity(entity)
          erase_cell_space(cell_space, erase_sketchup_group: false)
        end

        def state_erased(entity)
          return if @erasing

          state = find_state_for_entity(entity)
          erase_state(state, erase_sketchup_instance: false)
        end

        def erase_cell_space(cell_space, erase_sketchup_group: true)
          return if cell_space.nil?

          erase_guard do
            state = cell_space.duality_state
            erase_transitions_for_state(state)
            state.erase! if state&.valid?
            unregister_state(state)
            cell_space.erase! if erase_sketchup_group && cell_space.valid?
            unregister_cell_space(cell_space)
            erase_adjacency_for_cell_space(cell_space)
          end
        end

        def erase_state(state, erase_sketchup_instance: true)
          return if state.nil?

          erase_guard do
            cell_space = state.duality_cell
            erase_transitions_for_state(state)
            cell_space.erase! if cell_space&.valid?
            state.erase! if erase_sketchup_instance && state.valid?
            unregister_cell_space(cell_space)
            unregister_state(state)
            erase_adjacency_for_cell_space(cell_space)
          end
        end

        def update_transitions_for_state(state)
          return if state.nil?

          @transitions.each do |transition|
            next unless transition.connected_to?(state)

            write_transition_attributes(transition) if update_transition(transition)
          end
        end

        def space_features_changed(entity)
          return if @constraining_space_features || @erasing
          return unless entity&.valid?

          @constraining_space_features = true
          enforce_space_features_constraints
        ensure
          @constraining_space_features = false
        end

        def space_features_erased(entity)
          @primal_group = nil if entity == @primal_group
          @dual_group = nil if entity == @dual_group
          @space_features_observed_ids.delete(entity.persistent_id)
          @space_features_expected_names.delete(entity.persistent_id)
          @space_features_last_transforms.delete(entity.persistent_id)
        rescue StandardError
          nil
        end

        private

        def ensure_space_features_groups
          Utils::Materials.ensure_all

          model = Sketchup.active_model
          entities = model.active_entities

          @primal_group = find_group(entities, PRIMAL_GROUP_NAME)
          unless @primal_group&.valid?
            @primal_group = entities.add_group
            @primal_group.name = PRIMAL_GROUP_NAME
          end
          attach_space_features_observer(@primal_group, PRIMAL_GROUP_NAME)

          @dual_group = find_group(entities, DUAL_GROUP_NAME)
          unless @dual_group&.valid?
            @dual_group = entities.add_group
            @dual_group.name = DUAL_GROUP_NAME
          end
          attach_space_features_observer(@dual_group, DUAL_GROUP_NAME)
        end

        def find_group(entities, name)
          entities.grep(Sketchup::Group).find { |group| group.valid? && group.name == name }
        end

        def place_cell_group(sketchup_group)
          if inside_primal_group?(sketchup_group)
            return sketchup_group
          end

          raise ArgumentError, 'IndoorGML_PrimalSpaceFeatures is not ready' unless @primal_group&.valid?

          clone_group_under_primal_space(sketchup_group)
        end

        def clone_group_under_primal_space(sketchup_group)
          local_transformation = @primal_group.transformation.inverse * Utils::Transformation.entity_world_transformation(sketchup_group)
          cell_space_entity = @primal_group.entities.add_instance(sketchup_group.definition, local_transformation)
          raise ArgumentError, 'Could not create CellSpace entity' unless cell_space_entity&.valid?

          if cell_space_entity.respond_to?(:to_group)
            cell_space_entity = cell_space_entity.to_group
          end
          cell_space_entity.make_unique if cell_space_entity.respond_to?(:make_unique)

          sketchup_group.erase! if sketchup_group.valid?
          recenter_cell_space_geometry(cell_space_entity)
          cell_space_entity
        end

        def recenter_cell_space_geometry(cell_space_entity)
          center = cell_space_entity.definition.bounds.center
          return if center.distance(ORIGIN) <= 0.001

          set_group_transformation(
            cell_space_entity,
            cell_space_entity.transformation * Geom::Transformation.translation(center)
          )
          cell_space_entity.definition.entities.transform_entities(
            Geom::Transformation.translation(center.vector_to(ORIGIN)),
            cell_space_entity.definition.entities.to_a
          )
        end

        def attach_space_features_observer(group, expected_name)
          return unless group&.valid?

          persistent_id = group.persistent_id
          @space_features_expected_names[persistent_id] = expected_name
          group.name = expected_name unless group.name == expected_name
          return if @space_features_observed_ids[persistent_id]

          group.add_observer(@space_features_observer)
          @space_features_observed_ids[persistent_id] = true
          @space_features_last_transforms[persistent_id] = group.transformation
          synchronize_space_features_from(@primal_group) if group == @dual_group && @primal_group&.valid?
        end

        def enforce_space_features_constraints
          ordered_space_features_groups.each do |group|
            next unless group&.valid?

            restore_space_features_name(group)
            next if restore_space_features_scale(group)

            last_transform = @space_features_last_transforms[group.persistent_id]
            next if last_transform && Utils::Transformation.same?(group.transformation, last_transform)

            synchronize_space_features_from(group)
          end
        end

        def ordered_space_features_groups
          [@primal_group, @dual_group].compact
        end

        def restore_space_features_name(group)
          expected_name = @space_features_expected_names[group.persistent_id]
          return if expected_name.nil? || group.name == expected_name

          UI.messagebox('이름을 변경할 수 없는 Group입니다.')
          group.name = expected_name
        end

        def restore_space_features_scale(group)
          return false unless Utils::Transformation.scaled?(group.transformation)

          UI.messagebox('크기를 조절할 수 없는 Group입니다.')
          set_group_transformation(group, @space_features_last_transforms[group.persistent_id] || Geom::Transformation.new)
          true
        end

        def synchronize_space_features_from(source_group)
          return unless source_group&.valid?
          return if Utils::Transformation.scaled?(source_group.transformation)

          ordered_space_features_groups.each do |group|
            next unless group&.valid?
            next if group == source_group
            next if Utils::Transformation.same?(group.transformation, source_group.transformation)

            set_group_transformation(group, source_group.transformation)
          end

          ordered_space_features_groups.each do |group|
            next unless group&.valid?

            @space_features_last_transforms[group.persistent_id] = group.transformation
          end
        end

        def set_group_transformation(group, transformation)
          if group.respond_to?(:transformation=)
            group.transformation = transformation
          else
            group.transform!(group.transformation.inverse * transformation)
          end
        end

        def inside_primal_group?(sketchup_group)
          Utils::Transformation.direct_child_of_root?(sketchup_group, @primal_group)
        rescue StandardError
          false
        end

        def cell_space_local_origin(cell_space)
          ensure_cell_space_is_child_of_primal_space!(cell_space)
          Utils::Transformation.entity_origin_in_root_local(cell_space.sketchup_group, @primal_group)
        end

        def state_local_position(state)
          ensure_state_is_child_of_dual_space!(state)
          Utils::Transformation.entity_origin_in_root_local(state.sketchup_component_instance, @dual_group)
        end

        def move_state_to_local_position(state, local_position)
          ensure_state_is_child_of_dual_space!(state)
          Utils::Transformation.move_entity_origin_in_root_local_to(state.sketchup_component_instance, @dual_group, local_position)
          update_state_position(state, local_position)
        end

        def move_cell_space_to_local_position(cell_space, local_position)
          ensure_cell_space_is_child_of_primal_space!(cell_space)
          Utils::Transformation.move_entity_origin_in_root_local_to(cell_space.sketchup_group, @primal_group, local_position)
        end

        def ensure_cell_space_is_child_of_primal_space!(cell_space)
          Utils::Transformation.ensure_direct_child_of_root!(
            cell_space.sketchup_group,
            @primal_group,
            "[IndoorGML] Coordinate warning: CellSpace #{cell_space.sketchup_group.name} is not a child of #{PRIMAL_GROUP_NAME}"
          )
        end

        def ensure_state_is_child_of_dual_space!(state)
          Utils::Transformation.ensure_direct_child_of_root!(
            state.sketchup_component_instance,
            @dual_group,
            "[IndoorGML] Coordinate warning: State #{state.sketchup_component_instance.name} is not a child of #{DUAL_GROUP_NAME}"
          )
        end

        def register_cell_space(cell_space)
          @cell_spaces << cell_space
          @cell_spaces_by_entity[cell_space.sketchup_group] = cell_space
          @cell_spaces_by_entity_id[cell_space.sketchup_group.persistent_id] = cell_space
          cell_space.sketchup_group.add_observer(@cell_space_observer)
        end

        def name_cell_space_entity(cell_space)
          cell_space.sketchup_group.name = "[#{CellSpaceType.label(cell_space.cell_type)}]-#{cell_space.id}"
        end

        def apply_cell_space_material(cell_space)
          material = Utils::Materials.cell_space(cell_space.cell_type)
          cell_space.sketchup_group.material = material
          cell_space.sketchup_group.entities.each do |entity|
            entity.material = material if entity.is_a?(Sketchup::Face)
          end
        end

        def register_state(state)
          @states << state
          @states_by_entity[state.sketchup_component_instance] = state
          @states_by_entity_id[state.sketchup_component_instance.persistent_id] = state
          state.sketchup_component_instance.add_observer(@state_observer)
        end

        def unregister_cell_space(cell_space)
          return if cell_space.nil?

          @cell_spaces.delete(cell_space)
          @cell_spaces_by_entity.delete(cell_space.sketchup_group)
          @cell_spaces_by_entity_id.delete(cell_space.sketchup_group_id)
        end

        def unregister_state(state)
          return if state.nil?

          @states.delete(state)
          @states_by_entity.delete(state.sketchup_component_instance)
          @states_by_entity_id.delete(state.sketchup_component_instance_id)
        end

        def connect_states(state1, state2)
          ensure_space_features_groups

          cell1 = state1&.duality_cell
          cell2 = state2&.duality_cell
          return nil if cell1.nil? || cell2.nil?

          create_or_update_transition_for_pair(cell1, cell2)
        end

        def synchronize_adjacency_and_transitions_for_cell_space(cell_space)
          return if cell_space.nil? || !cell_space.valid? || !cell_space.duality_state&.valid?

          @cell_spaces.each do |other_cell_space|
            next if other_cell_space.nil? || other_cell_space == cell_space
            next unless other_cell_space.valid? && other_cell_space.duality_state&.valid?

            pair_key = cell_pair_key(cell_space, other_cell_space)
            adjacency_axis = Utils::Geometry.adjacency_axis(cell_space.sketchup_group, other_cell_space.sketchup_group)
            if transition_allowed_between?(cell_space, other_cell_space, adjacency_axis)
              @adjacent_cell_space_pairs[pair_key] = [cell_space, other_cell_space]
              create_or_update_transition_for_pair(cell_space, other_cell_space)
            else
              erase_transition_for_pair_key(pair_key)
            end
          end
        end

        def erase_adjacency_for_cell_space(cell_space)
          return if cell_space.nil?

          @adjacent_cell_space_pairs.keys.each do |pair_key|
            erase_transition_for_pair_key(pair_key) if pair_key.split(':').include?(cell_space.id)
          end

          @transitions_by_cell_pair.keys.each do |pair_key|
            erase_transition_for_pair_key(pair_key) if pair_key.split(':').include?(cell_space.id)
          end
        end

        def create_or_update_transition_for_pair(cell1, cell2)
          return nil if cell1.nil? || cell2.nil?
          return nil if cell1 == cell2
          return nil unless cell1.valid? && cell2.valid?
          return nil unless cell1.duality_state&.valid? && cell2.duality_state&.valid?

          pair_key = cell_pair_key(cell1, cell2)
          transition = @transitions_by_cell_pair[pair_key]
          unless transition&.valid?
            transition = Transition.new(
              cell1.duality_state,
              cell2.duality_state,
              @dual_group.entities,
              cell1: cell1,
              cell2: cell2
            )
            @transitions << transition
            @transitions_by_cell_pair[pair_key] = transition
          end

          return nil unless update_transition(transition)

          register_transition_with_states(transition)
          write_transition_attributes(transition)
          transition
        end

        def erase_transition_for_pair_key(pair_key)
          transition = @transitions_by_cell_pair.delete(pair_key)
          return if transition.nil?

          unregister_transition_from_states(transition)
          transition.erase!
          @transitions.delete(transition)
          @adjacent_cell_space_pairs.delete(pair_key)
        end

        def cell_pair_key(cell1, cell2)
          [cell1.id, cell2.id].sort.join(':')
        end

        def transition_allowed_between?(cell1, cell2, adjacency_axis)
          return false if adjacency_axis.nil?
          return false if cell1.cell_type == CellSpaceType::GENERAL && cell2.cell_type == CellSpaceType::GENERAL

          return adjacency_axis != :z if transition_space_pair?(cell1, cell2)

          return false if transfer_space_pair?(cell1, cell2) && adjacency_axis != :z

          true
        end

        def transition_space_pair?(cell1, cell2)
          cell1.cell_type == CellSpaceType::TRANSITION || cell2.cell_type == CellSpaceType::TRANSITION
        end

        def transfer_space_pair?(cell1, cell2)
          cell1.cell_type == CellSpaceType::TRANSFER || cell2.cell_type == CellSpaceType::TRANSFER
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

        def update_state_position(state, local_position)
          state.update_position(local_position)
          write_state_attributes(state)
        end

        def erase_transitions_for_state(state)
          return if state.nil?

          @transitions.delete_if do |transition|
            next false unless transition.connected_to?(state)

            @transitions_by_cell_pair.delete(cell_pair_key(transition.cell1, transition.cell2)) if transition.cell1 && transition.cell2
            @adjacent_cell_space_pairs.delete(cell_pair_key(transition.cell1, transition.cell2)) if transition.cell1 && transition.cell2
            unregister_transition_from_states(transition)
            transition.erase!
            true
          end
        end

        def write_attributes(cell_space)
          group = cell_space.sketchup_group
          state = cell_space.duality_state.sketchup_component_instance

          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'feature', 'CellSpace')
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'id', cell_space.id)
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'name', group.name)
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'cell_type', CellSpaceType.label(cell_space.cell_type))
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'duality_state_id', cell_space.duality_state.id)
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'indoor_gml_version', INDOOR_GML_VERSION)

          state.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'feature', 'State')
          state.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'id', cell_space.duality_state.id)
          state.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'name', cell_space.duality_state.name)
          state.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'duality_cell_id', cell_space.id)
          state.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'indoor_gml_version', INDOOR_GML_VERSION)
          write_state_attributes(cell_space.duality_state)
        end

        def write_cell_space_attributes(cell_space)
          group = cell_space.sketchup_group

          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'feature', 'CellSpace')
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'id', cell_space.id)
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'name', group.name)
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'cell_type', CellSpaceType.label(cell_space.cell_type))
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'duality_state_id', cell_space.duality_state.id) if cell_space.duality_state
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'indoor_gml_version', INDOOR_GML_VERSION)
        end

        def write_state_attributes(state)
          return unless state&.valid?

          component = state.sketchup_component_instance
          component.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'feature', 'State')
          component.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'id', state.id)
          component.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'name', state.name)
          component.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'duality_cell_id', state.duality_cell.id)
          component.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'transition_ids', state.transition_ids)
          component.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'position_x', state.position.x.to_f)
          component.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'position_y', state.position.y.to_f)
          component.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'position_z', state.position.z.to_f)
          component.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'indoor_gml_version', INDOOR_GML_VERSION)
        end

        def write_transition_attributes(transition)
          return unless transition.edge&.valid?

          transition.edge.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'feature', 'Transition')
          transition.edge.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'id', transition.id)
          transition.edge.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'name', transition.name)
          transition.edge.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'state1_id', transition.state1.id)
          transition.edge.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'state2_id', transition.state2.id)
          transition.edge.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'cell1_id', transition.cell1.id) if transition.cell1
          transition.edge.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'cell2_id', transition.cell2.id) if transition.cell2
          transition.edge.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'indoor_gml_version', INDOOR_GML_VERSION)
        end

        def update_transition(transition)
          transition.update(
            state_local_position(transition.state1),
            state_local_position(transition.state2)
          )
        end

        def converted_group?(sketchup_group)
          sketchup_group.get_attribute(ATTRIBUTE_DICTIONARY_NAME, 'feature') == 'CellSpace'
        end

        def find_cell_space_for_entity(entity)
          @cell_spaces_by_entity[entity] || @cell_spaces_by_entity_id[entity.persistent_id]
        rescue StandardError
          @cell_spaces_by_entity[entity]
        end

        def find_state_for_entity(entity)
          @states_by_entity[entity] || @states_by_entity_id[entity.persistent_id]
        rescue StandardError
          @states_by_entity[entity]
        end

        def sync
          @syncing = true
          yield
        ensure
          @syncing = false
        end

        def erase_guard
          @erasing = true
          yield
        ensure
          @erasing = false
        end
      end

    end
  end
end
