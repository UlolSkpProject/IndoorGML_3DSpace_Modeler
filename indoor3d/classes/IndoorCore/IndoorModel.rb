# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class IndoorModel
        PRIMAL_GROUP_NAME = 'IndoorGML_PrimalSpaceFeatures'
        DUAL_GROUP_NAME = 'IndoorGML_DualSpaceFeatures'
        PRIMAL_GROUP_FEATURE = 'primalspace'
        DUAL_GROUP_FEATURE = 'dualspace'
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml'
        INDOOR_GML_VERSION = '1.1'

        attr_reader :cell_spaces
        attr_reader :states
        attr_reader :transitions
        attr_reader :cells
        attr_reader :nodes
        attr_reader :links
        attr_reader :doors
        attr_reader :transfer_spaces
        attr_reader :pois
        attr_reader :building
        attr_reader :floors
        attr_reader :model
        attr_reader :edit_mode
        attr_reader :primal_group
        attr_reader :dual_group

        def self.current
          @current ||= new
        end

        def initialize
          @model = Sketchup.active_model
          @cell_spaces = []
          @states = []
          @transitions = []
          @cells = @cell_spaces
          @nodes = @states
          @links = @transitions
          @doors = []
          @transfer_spaces = []
          @pois = []
          @building = nil
          @floors = []
          @cell_creation_count = 0
          @door_creation_count = 0
          @node_creation_count = 0
          @link_creation_count = 0
          @poi_creation_count = 0
          @floor_creation_count = 0
          @edit_mode = :none
          @cell_spaces_by_entity = {}
          @cell_spaces_by_entity_id = {}
          @cell_spaces_by_sketchup_entity_id = {}
          @states_by_entity = {}
          @states_by_entity_id = {}
          @states_by_sketchup_entity_id = {}
          @transitions_by_entity = {}
          @transitions_by_entity_id = {}
          @transitions_by_sketchup_entity_id = {}
          @adjacent_cell_space_pairs = {}
          @transitions_by_cell_pair = {}
          @cell_space_observer = CellSpaceObserver.new(self)
          @state_observer = StateObserver.new(self)
          @space_features_observer = SpaceFeaturesObserver.new(self)
          @root_entities_observer = Indoor3DGmlRootEntitiesObserver.new(self)
          @primal_entities_observer = Indoor3DGmlPrimalEntitiesObserver.new(self)
          @dual_entities_observer = Indoor3DGmlDualEntitiesObserver.new(self)
          @cell_space_observed_ids = {}
          @state_observed_ids = {}
          @space_features_observed_ids = {}
          @entities_observed_ids = {}
          @space_features_expected_names = {}
          @space_features_last_transforms = {}
          @syncing = false
          @erasing = false
          @relocating_entity = false
          @refreshing_runtime = false
          @constraining_space_features = false
          @primal_group = nil
          @dual_group = nil
        end

        def convert_group_to_cell_space(sketchup_group, cell_type = CellSpaceType::GENERAL)
          raise ArgumentError, 'Group is already converted to CellSpace' if converted_group?(sketchup_group)

          @cell_creation_count += 1
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
            remove_cell_space_from_type_runtime_lists(cell_space)
            cell_space.cell_type = cell_type
            update_cell_space_type_runtime_lists(cell_space)
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
          cell_space = refresh_and_find_cell_space(entity) if stale_cell_space_runtime?(cell_space, entity)
          return if cell_space.nil? || !cell_space.valid?

          sync do
            state = cell_space.duality_state
            unless state&.valid?
              cell_space = refresh_and_find_cell_space(entity)
              state = cell_space&.duality_state
            end
            if state&.valid?
              local_position = cell_space_local_origin(cell_space)
              move_state_to_local_position(state, local_position)
            end
            synchronize_adjacency_and_transitions_for_cell_space(cell_space)
          end
        ensure
          lock_indoor_entity(entity)
        end

        def state_changed(entity)
          return if @syncing || @erasing

          state = find_state_for_entity(entity)
          state = refresh_and_find_state(entity) if stale_state_runtime?(state, entity)
          return if state.nil? || !state.valid?

          sync do
            cell_space = state.duality_cell
            local_position = state_local_position(state)
            update_state_position(state, local_position)
            move_cell_space_to_local_position(cell_space, local_position) if cell_space&.valid?
            synchronize_adjacency_and_transitions_for_cell_space(cell_space) if cell_space&.valid?
          end
        ensure
          lock_indoor_entity(entity)
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
            unlock_indoor_entity(state.sketchup_component_instance) if state&.valid?
            state.erase! if state&.valid?
            unregister_state(state)
            unlock_indoor_entity(cell_space.sketchup_group) if erase_sketchup_group && cell_space.valid?
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
            unlock_indoor_entity(cell_space.sketchup_group) if cell_space&.valid?
            cell_space.erase! if cell_space&.valid?
            unlock_indoor_entity(state.sketchup_component_instance) if erase_sketchup_instance && state.valid?
            state.erase! if erase_sketchup_instance && state.valid?
            unregister_cell_space(cell_space)
            unregister_state(state)
            erase_adjacency_for_cell_space(cell_space)
          end
        end

        def refresh_runtime_data
          return true if @refreshing_runtime

          @refreshing_runtime = true
          sync do
            @model = Sketchup.active_model
            ensure_space_features_groups
            reset_runtime_collections
            restore_cell_spaces_from_primal_group
            restore_states_from_dual_group
            restore_transitions_from_dual_group
            @cell_spaces.each { |cell_space| synchronize_adjacency_and_transitions_for_cell_space(cell_space) }
            update_runtime_counts
          end
          puts "[IndoorGML] Runtime refreshed: cells=#{@cell_spaces.length}, states=#{@states.length}, transitions=#{@transitions.length}"
          true
        ensure
          @refreshing_runtime = false
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
          lock_indoor_entity(entity)
          @constraining_space_features = false
        end

        def root_entity_added(entity)
          return if @relocating_entity
          return unless indoor_gml_entity?(entity)

          feature = indoor_feature(entity)
          if space_features_feature?(feature)
            register_space_features_entity(entity, feature)
            return
          end

          ensure_space_features_groups
          case feature
          when 'CellSpace'
            relocate_indoor_entity(entity, @primal_group.entities, @primal_group)
          when 'State', 'Transition'
            relocate_indoor_entity(entity, @dual_group.entities, @dual_group)
          else
            lock_indoor_entity(entity)
          end
        end

        def root_entity_removed(entity_id)
          return if @erasing || @relocating_entity

          puts "[IndoorGML] Root entity removed: entity_id=#{entity_id}"
        end

        def primal_entity_added(entity)
          return if @relocating_entity
          return unless indoor_gml_entity?(entity)

          ensure_space_features_groups
          if indoor_feature(entity) == 'CellSpace'
            cell_space = find_cell_space_for_entity(entity)
            attach_cell_space_observer(entity)
            if stale_cell_space_runtime?(cell_space, entity)
              puts '[IndoorGML] CellSpace runtime stale. Refreshing runtime data.'
              refresh_runtime_data
            elsif cell_space
              lock_indoor_entity(entity)
            else
              puts '[IndoorGML] CellSpace runtime data missing. Refresh is required.'
            end
          elsif dual_feature?(entity)
            relocate_indoor_entity(entity, @dual_group.entities, @dual_group)
          else
            relocate_indoor_entity(entity, Sketchup.active_model.entities)
          end
        end

        def primal_entity_removed(entity_id)
          return if @erasing || @relocating_entity

          cell_space = @cell_spaces_by_sketchup_entity_id[entity_id]
          puts "[IndoorGML] Primal entity removed: entity_id=#{entity_id} cell_space=#{cell_space&.id || 'missing'}"
          erase_cell_space(cell_space, erase_sketchup_group: false) if cell_space
        end

        def dual_entity_added(entity)
          return if @relocating_entity
          return unless indoor_gml_entity?(entity)

          ensure_space_features_groups
          case indoor_feature(entity)
          when 'State'
            state = find_state_for_entity(entity)
            attach_state_observer(entity)
            if stale_state_runtime?(state, entity)
              puts '[IndoorGML] State runtime stale. Refreshing runtime data.'
              refresh_runtime_data
            elsif state
              lock_indoor_entity(entity)
            else
              puts '[IndoorGML] State runtime data missing. Refresh is required.'
            end
          when 'Transition'
            lock_indoor_entity(entity)
          when 'CellSpace'
            relocate_indoor_entity(entity, @primal_group.entities, @primal_group)
          else
            relocate_indoor_entity(entity, Sketchup.active_model.entities)
          end
        end

        def dual_entity_removed(entity_id)
          return if @erasing || @relocating_entity

          state = @states_by_sketchup_entity_id[entity_id]
          puts "[IndoorGML] Dual entity removed: entity_id=#{entity_id} state=#{state&.id || 'missing'}"
          erase_state(state, erase_sketchup_instance: false) if state

          transition = @transitions_by_sketchup_entity_id[entity_id]
          puts "[IndoorGML] Dual transition removed: entity_id=#{entity_id} transition=#{transition&.id || 'missing'}"
          erase_transition(transition) if transition
        end

        def space_features_erased(entity)
          @primal_group = nil if entity == @primal_group
          @dual_group = nil if entity == @dual_group
          @space_features_observed_ids.delete(entity.object_id)
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
          write_space_features_attributes(@primal_group, PRIMAL_GROUP_FEATURE)
          ensure_space_features_origin_point(@primal_group)

          @dual_group = find_group(entities, DUAL_GROUP_NAME)
          unless @dual_group&.valid?
            @dual_group = entities.add_group
            @dual_group.name = DUAL_GROUP_NAME
          end
          attach_space_features_observer(@dual_group, DUAL_GROUP_NAME)
          write_space_features_attributes(@dual_group, DUAL_GROUP_FEATURE)
          ensure_space_features_origin_point(@dual_group)
          attach_entities_observers
          lock_space_features_groups
        end

        def reset_runtime_collections
          @cell_spaces = []
          @states = []
          @transitions = []
          @cells = @cell_spaces
          @nodes = @states
          @links = @transitions
          @doors = []
          @transfer_spaces = []
          @pois = []
          @cell_spaces_by_entity = {}
          @cell_spaces_by_entity_id = {}
          @cell_spaces_by_sketchup_entity_id = {}
          @states_by_entity = {}
          @states_by_entity_id = {}
          @states_by_sketchup_entity_id = {}
          @transitions_by_entity = {}
          @transitions_by_entity_id = {}
          @transitions_by_sketchup_entity_id = {}
          @adjacent_cell_space_pairs = {}
          @transitions_by_cell_pair = {}
        end

        def update_runtime_counts
          @cell_creation_count = @cell_spaces.length
          @node_creation_count = @states.length
          @link_creation_count = @transitions.length
          @door_creation_count = @doors.length
          @poi_creation_count = @pois.length
          @floor_creation_count = @floors.length
        end

        def restore_cell_spaces_from_primal_group
          return unless @primal_group&.valid?

          indoor_children(@primal_group.entities, 'CellSpace').each do |entity|
            cell_space = restore_cell_space(entity)
            register_cell_space(cell_space) if cell_space
          end
        end

        def restore_states_from_dual_group
          return unless @dual_group&.valid?

          cells_by_id = @cell_spaces.each_with_object({}) { |cell_space, hash| hash[cell_space.id] = cell_space }
          indoor_children(@dual_group.entities, 'State').each do |entity|
            cell_id = indoor_attribute(entity, 'duality_cell_id')
            cell_space = cells_by_id[cell_id]
            unless cell_space
              puts "[IndoorGML] State restore skipped: missing CellSpace #{cell_id}"
              next
            end

            state = restore_state(entity, cell_space)
            next unless state

            cell_space.restore_duality_state(state)
            register_state(state)
          end
        end

        def restore_transitions_from_dual_group
          return unless @dual_group&.valid?

          states_by_id = @states.each_with_object({}) { |state, hash| hash[state.id] = state }
          cells_by_id = @cell_spaces.each_with_object({}) { |cell_space, hash| hash[cell_space.id] = cell_space }
          indoor_children(@dual_group.entities, 'Transition').each do |entity|
            state1 = states_by_id[indoor_attribute(entity, 'state1_id')]
            state2 = states_by_id[indoor_attribute(entity, 'state2_id')]
            unless state1 && state2
              puts "[IndoorGML] Transition restore skipped: missing State"
              next
            end

            cell1 = cells_by_id[indoor_attribute(entity, 'cell1_id')] || state1.duality_cell
            cell2 = cells_by_id[indoor_attribute(entity, 'cell2_id')] || state2.duality_cell
            transition = restore_transition(entity, state1, state2, cell1, cell2)
            next unless transition

            @transitions << transition
            @transitions_by_cell_pair[cell_pair_key(cell1, cell2)] = transition if cell1 && cell2
            @adjacent_cell_space_pairs[cell_pair_key(cell1, cell2)] = [cell1, cell2] if cell1 && cell2
            register_transition_entity(transition)
            register_transition_with_states(transition)
          end
        end

        def restore_cell_space(entity)
          CellSpace.restore(
            entity,
            CellSpaceType.from_label(indoor_attribute(entity, 'cell_type')),
            id: indoor_attribute(entity, 'id'),
            name: indoor_attribute(entity, 'name')
          )
        rescue StandardError => e
          puts "[IndoorGML] CellSpace restore failed: #{e.class}: #{e.message}"
          nil
        end

        def restore_state(entity, cell_space)
          State.restore(
            cell_space,
            entity,
            restored_state_position(entity),
            id: indoor_attribute(entity, 'id'),
            name: indoor_attribute(entity, 'name')
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
            id: indoor_attribute(entity, 'id'),
            name: indoor_attribute(entity, 'name')
          )
        rescue StandardError => e
          puts "[IndoorGML] Transition restore failed: #{e.class}: #{e.message}"
          nil
        end

        def restored_state_position(entity)
          x = indoor_attribute(entity, 'position_x')
          y = indoor_attribute(entity, 'position_y')
          z = indoor_attribute(entity, 'position_z')
          return Geom::Point3d.new(x.to_f, y.to_f, z.to_f) unless x.nil? || y.nil? || z.nil?

          Utils::Transformation.entity_origin_in_root_local(entity, @dual_group)
        end

        def indoor_children(entities, feature)
          entities.to_a.select do |entity|
            entity&.valid? && indoor_attribute(entity, 'feature') == feature
          end
        end

        def stale_cell_space_runtime?(cell_space, entity)
          return true if cell_space.nil?
          return true unless cell_space.valid?
          return true unless cell_space.sketchup_group == entity
          return true unless cell_space.duality_state&.valid?

          false
        rescue StandardError
          true
        end

        def stale_state_runtime?(state, entity)
          return true if state.nil?
          return true unless state.valid?
          return true unless state.sketchup_component_instance == entity
          return true unless state.duality_cell&.valid?

          false
        rescue StandardError
          true
        end

        def refresh_and_find_cell_space(entity)
          refresh_runtime_data
          find_cell_space_for_entity(entity)
        end

        def refresh_and_find_state(entity)
          refresh_runtime_data
          find_state_for_entity(entity)
        end

        def find_group(entities, name)
          expected_feature = space_features_feature_for_name(name)
          entities.grep(Sketchup::Group).find do |group|
            group.valid? && indoor_feature(group) == expected_feature
          end || entities.grep(Sketchup::Group).find { |group| group.valid? && group.name == name }
        end

        def space_features_feature_for_name(name)
          return PRIMAL_GROUP_FEATURE if name == PRIMAL_GROUP_NAME
          return DUAL_GROUP_FEATURE if name == DUAL_GROUP_NAME

          nil
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
          observer_key = group.object_id
          @space_features_expected_names[persistent_id] = expected_name
          with_unlocked(group) { group.name = expected_name } unless group.name == expected_name
          return if @space_features_observed_ids[observer_key]

          group.add_observer(@space_features_observer)
          @space_features_observed_ids[observer_key] = true
          @space_features_last_transforms[persistent_id] = group.transformation
          synchronize_space_features_from(@primal_group) if group == @dual_group && @primal_group&.valid?
        end

        def attach_entities_observers
          model = Sketchup.active_model
          attach_entities_observer(:root, model.entities, @root_entities_observer)
          attach_entities_observer(:primal, @primal_group.entities, @primal_entities_observer) if @primal_group&.valid?
          attach_entities_observer(:dual, @dual_group.entities, @dual_entities_observer) if @dual_group&.valid?
        end

        def attach_entities_observer(scope, entities, observer)
          return unless entities && observer

          key = [scope, entities.object_id]
          return if @entities_observed_ids[key]

          entities.add_observer(observer)
          @entities_observed_ids[key] = true
        end

        def register_space_features_entity(entity, feature)
          unless entity.is_a?(Sketchup::Group)
            puts "[IndoorGML] SpaceFeatures restore skipped: #{feature} is #{entity.class}"
            return
          end

          case feature
          when PRIMAL_GROUP_FEATURE
            @primal_group = entity
            attach_space_features_observer(@primal_group, PRIMAL_GROUP_NAME)
            write_space_features_attributes(@primal_group, PRIMAL_GROUP_FEATURE)
            ensure_space_features_origin_point(@primal_group)
            attach_entities_observer(:primal, @primal_group.entities, @primal_entities_observer)
          when DUAL_GROUP_FEATURE
            @dual_group = entity
            attach_space_features_observer(@dual_group, DUAL_GROUP_NAME)
            write_space_features_attributes(@dual_group, DUAL_GROUP_FEATURE)
            ensure_space_features_origin_point(@dual_group)
            attach_entities_observer(:dual, @dual_group.entities, @dual_entities_observer)
          end
        end

        def write_space_features_attributes(group, feature)
          return unless group&.valid?

          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'feature', feature)
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'name', group.name)
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'indoor_gml_version', INDOOR_GML_VERSION)
        end

        def ensure_space_features_origin_point(group)
          return unless group&.valid?
          return if origin_construction_point?(group)

          group.entities.add_cpoint(ORIGIN)
        rescue StandardError => e
          puts "[IndoorGML] Origin point creation failed: #{e.class}: #{e.message}"
        end

        def origin_construction_point?(group)
          group.entities.grep(Sketchup::ConstructionPoint).any? do |point|
            point.valid? && point.position.distance(ORIGIN) <= 0.001
          end
        rescue StandardError
          false
        end

        def attach_cell_space_observer(entity)
          attach_entity_observer(entity, @cell_space_observer, @cell_space_observed_ids)
        end

        def attach_state_observer(entity)
          attach_entity_observer(entity, @state_observer, @state_observed_ids)
        end

        def attach_entity_observer(entity, observer, observed_ids)
          return unless entity&.valid? && observer

          key = entity.object_id
          return if observed_ids[key]

          attached = entity.add_observer(observer)
          puts "[IndoorGML] #{observer.class} attached=#{attached} entity_id=#{entity.entityID}"
          observed_ids[key] = true
        rescue StandardError => e
          puts "[IndoorGML] Observer attach failed: #{e.class}: #{e.message}"
        end

        def lock_space_features_groups
          lock_indoor_entity(@primal_group)
          lock_indoor_entity(@dual_group)
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
          with_unlocked(group) { group.name = expected_name }
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
          with_unlocked(group) do
            if group.respond_to?(:transformation=)
              group.transformation = transformation
            else
              group.transform!(group.transformation.inverse * transformation)
            end
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
          with_unlocked(state.sketchup_component_instance) do
            Utils::Transformation.move_entity_origin_in_root_local_to(state.sketchup_component_instance, @dual_group, local_position)
          end
          update_state_position(state, local_position)
        end

        def move_cell_space_to_local_position(cell_space, local_position)
          ensure_cell_space_is_child_of_primal_space!(cell_space)
          with_unlocked(cell_space.sketchup_group) do
            Utils::Transformation.move_entity_origin_in_root_local_to(cell_space.sketchup_group, @primal_group, local_position)
          end
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
          update_cell_space_type_runtime_lists(cell_space)
          @cell_spaces_by_entity[cell_space.sketchup_group] = cell_space
          @cell_spaces_by_entity_id[cell_space.sketchup_group.persistent_id] = cell_space
          @cell_spaces_by_sketchup_entity_id[cell_space.sketchup_group.entityID] = cell_space
          attach_cell_space_observer(cell_space.sketchup_group)
          lock_indoor_entity(cell_space.sketchup_group)
        end

        def name_cell_space_entity(cell_space)
          with_unlocked(cell_space.sketchup_group) do
            cell_space.sketchup_group.name = "[#{CellSpaceType.label(cell_space.cell_type)}]-#{cell_space.id}"
          end
        end

        def apply_cell_space_material(cell_space)
          material = Utils::Materials.cell_space(cell_space.cell_type)
          with_unlocked(cell_space.sketchup_group) do
            cell_space.sketchup_group.material = material
            cell_space.sketchup_group.entities.each do |entity|
              entity.material = material if entity.is_a?(Sketchup::Face)
            end
          end
        end

        def update_cell_space_type_runtime_lists(cell_space)
          return if cell_space.nil?

          @doors << cell_space if cell_space.cell_type == CellSpaceType::TRANSITION && !@doors.include?(cell_space)
          @transfer_spaces << cell_space if cell_space.cell_type == CellSpaceType::TRANSFER && !@transfer_spaces.include?(cell_space)
        end

        def remove_cell_space_from_type_runtime_lists(cell_space)
          return if cell_space.nil?

          @doors.delete(cell_space)
          @transfer_spaces.delete(cell_space)
        end

        def register_state(state)
          @states << state
          @node_creation_count += 1
          @states_by_entity[state.sketchup_component_instance] = state
          @states_by_entity_id[state.sketchup_component_instance.persistent_id] = state
          @states_by_sketchup_entity_id[state.sketchup_component_instance.entityID] = state
          attach_state_observer(state.sketchup_component_instance)
          lock_indoor_entity(state.sketchup_component_instance)
        end

        def unregister_cell_space(cell_space)
          return if cell_space.nil?

          @cell_spaces.delete(cell_space)
          remove_cell_space_from_type_runtime_lists(cell_space)
          @cell_spaces_by_entity.delete(cell_space.sketchup_group)
          @cell_spaces_by_entity_id.delete(cell_space.sketchup_group_id)
          @cell_spaces_by_sketchup_entity_id.delete_if { |_entity_id, mapped_cell_space| mapped_cell_space == cell_space }
          @cell_space_observed_ids.delete(cell_space.sketchup_group.object_id)
        end

        def unregister_state(state)
          return if state.nil?

          @states.delete(state)
          @states_by_entity.delete(state.sketchup_component_instance)
          @states_by_entity_id.delete(state.sketchup_component_instance_id)
          @states_by_sketchup_entity_id.delete_if { |_entity_id, mapped_state| mapped_state == state }
          @state_observed_ids.delete(state.sketchup_component_instance.object_id)
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
            @link_creation_count += 1
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
          register_transition_entity(transition)
          write_transition_attributes(transition)
          lock_indoor_entity(transition.edge)
          transition
        end

        def erase_transition_for_pair_key(pair_key)
          transition = @transitions_by_cell_pair.delete(pair_key)
          return if transition.nil?

          erase_transition(transition)
          @adjacent_cell_space_pairs.delete(pair_key)
        end

        def erase_transition(transition)
          return if transition.nil?

          unregister_transition_entity(transition)
          unregister_transition_from_states(transition)
          unlock_indoor_entity(transition.edge)
          transition.erase!
          @transitions.delete(transition)
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

        def register_transition_entity(transition)
          return unless transition&.edge&.valid?

          @transitions_by_entity[transition.edge] = transition
          @transitions_by_entity_id[transition.edge.persistent_id] = transition
          @transitions_by_sketchup_entity_id[transition.edge.entityID] = transition
        end

        def unregister_transition_entity(transition)
          return if transition.nil?

          @transitions_by_entity.delete(transition.edge)
          @transitions_by_entity_id.delete_if { |_persistent_id, mapped_transition| mapped_transition == transition }
          @transitions_by_sketchup_entity_id.delete_if { |_entity_id, mapped_transition| mapped_transition == transition }
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
            erase_transition(transition)
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
          lock_indoor_entity(group)
          lock_indoor_entity(state)
        end

        def write_cell_space_attributes(cell_space)
          group = cell_space.sketchup_group

          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'feature', 'CellSpace')
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'id', cell_space.id)
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'name', group.name)
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'cell_type', CellSpaceType.label(cell_space.cell_type))
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'duality_state_id', cell_space.duality_state.id) if cell_space.duality_state
          group.set_attribute(ATTRIBUTE_DICTIONARY_NAME, 'indoor_gml_version', INDOOR_GML_VERSION)
          lock_indoor_entity(group)
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
          lock_indoor_entity(component)
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
          lock_indoor_entity(transition.edge)
        end

        def update_transition(transition)
          with_unlocked(transition.edge) do
            transition.update(
              state_local_position(transition.state1),
              state_local_position(transition.state2)
            )
          end
        end

        def indoor_gml_entity?(entity)
          indoor_feature(entity).to_s.length.positive?
        end

        def indoor_attribute(entity, key)
          entity.get_attribute(ATTRIBUTE_DICTIONARY_NAME, key)
        rescue StandardError
          nil
        end

        def indoor_feature(entity)
          indoor_attribute(entity, 'feature')
        end

        def dual_feature?(entity)
          ['State', 'Transition'].include?(indoor_feature(entity))
        end

        def space_features_feature?(feature)
          feature == PRIMAL_GROUP_FEATURE || feature == DUAL_GROUP_FEATURE
        end

        def relocate_indoor_entity(entity, target_entities, target_root_group = nil)
          return unless entity&.valid?
          return unless target_entities
          return if @relocating_entity

          if target_root_group&.valid? && Utils::Transformation.direct_child_of_root?(entity, target_root_group)
            lock_indoor_entity(entity)
            return entity
          end

          @relocating_entity = true
          copy = copy_entity_to_entities(entity, target_entities, target_root_group)
          unlock_indoor_entity(entity)
          entity.erase! if entity.valid?
          lock_indoor_entity(copy)
          copy
        rescue StandardError => e
          puts "[IndoorGML] Entity relocation failed: #{e.class}: #{e.message}"
          lock_indoor_entity(entity)
          nil
        ensure
          @relocating_entity = false
        end

        def copy_entity_to_entities(entity, target_entities, target_root_group)
          unless entity.respond_to?(:definition) && entity.respond_to?(:transformation)
            raise ArgumentError, "Unsupported IndoorGML entity type: #{entity.class}"
          end

          transformation = relocation_transformation(entity, target_root_group)
          copy = target_entities.add_instance(entity.definition, transformation)
          copy = copy.to_group if entity.is_a?(Sketchup::Group) && copy.respond_to?(:to_group)
          copy.make_unique if entity.is_a?(Sketchup::Group) && copy.respond_to?(:make_unique)
          copy.name = entity.name if copy.respond_to?(:name=) && entity.respond_to?(:name)
          copy.material = entity.material if copy.respond_to?(:material=) && entity.respond_to?(:material)
          copy_indoor_attributes(entity, copy)
          copy
        end

        def relocation_transformation(entity, target_root_group)
          world_transformation = Utils::Transformation.entity_world_transformation(entity)
          return world_transformation unless target_root_group&.valid?

          target_root_group.transformation.inverse * world_transformation
        end

        def copy_indoor_attributes(source, target)
          dictionary = source.attribute_dictionary(ATTRIBUTE_DICTIONARY_NAME)
          return if dictionary.nil?

          dictionary.each_pair do |key, value|
            target.set_attribute(ATTRIBUTE_DICTIONARY_NAME, key, value)
          end
        end

        def with_unlocked(entity)
          yield
        end

        def lock_indoor_entity(entity)
          # Lock policy is intentionally deferred until observer behavior is easier to test.
          true
        end

        def unlock_indoor_entity(entity)
          entity.locked = false if entity&.valid? && entity.respond_to?(:locked=)
        rescue StandardError
          true
        end

        def converted_group?(sketchup_group)
          sketchup_group.get_attribute(ATTRIBUTE_DICTIONARY_NAME, 'feature') == 'CellSpace'
        end

        def find_cell_space_for_entity(entity)
          @cell_spaces_by_entity[entity] ||
            @cell_spaces_by_entity_id[entity.persistent_id] ||
            @cell_spaces_by_sketchup_entity_id[entity.entityID]
        rescue StandardError
          @cell_spaces_by_entity[entity]
        end

        def find_state_for_entity(entity)
          @states_by_entity[entity] ||
            @states_by_entity_id[entity.persistent_id] ||
            @states_by_sketchup_entity_id[entity.entityID]
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
