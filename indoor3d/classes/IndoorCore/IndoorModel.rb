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
        attr_reader :doors
        attr_reader :transfer_spaces
        attr_reader :model
        attr_reader :primal_group
        attr_reader :dual_group

        def self.current
          @current ||= new
        end

        def initialize
          @model = Sketchup.active_model
          @feature_registry = FeatureRegistry.new
          bind_registry_collections
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
          @syncing = false
          @erasing = false
          @relocating_entity = false
          @refreshing_runtime = false
          @constraining_space_features = false
          @primal_group = nil
          @dual_group = nil
          @attribute_serializer = AttributeSerializer.new(
            dictionary_name: ATTRIBUTE_DICTIONARY_NAME,
            indoor_gml_version: INDOOR_GML_VERSION
          )
          @adjacency_service = AdjacencyService.new(
            @feature_registry,
            transition_builder: method(:create_or_update_transition_for_pair),
            transition_eraser: method(:erase_transition_for_pair_key)
          )
          @runtime_restorer = RuntimeRestorer.new(
            @feature_registry,
            @attribute_serializer,
            cell_space_registrar: method(:register_cell_space),
            state_registrar: method(:register_state)
          )
          @scene_group_guard = SceneGroupGuard.new(with_unlocked: method(:with_unlocked))
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
          begin
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
            find_existing_space_features_groups
            attach_existing_space_features_observers
            reset_runtime_collections
            @runtime_restorer.restore(primal_group: @primal_group, dual_group: @dual_group)
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
              synchronize_adjacency_and_transitions_for_cell_space(cell_space)
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

          cell_space = @feature_registry.cell_space_by_sketchup_entity_id(entity_id)
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

          state = @feature_registry.state_by_sketchup_entity_id(entity_id)
          puts "[IndoorGML] Dual entity removed: entity_id=#{entity_id} state=#{state&.id || 'missing'}"
          erase_state(state, erase_sketchup_instance: false) if state

          transition = @feature_registry.transition_by_sketchup_entity_id(entity_id)
          puts "[IndoorGML] Dual transition removed: entity_id=#{entity_id} transition=#{transition&.id || 'missing'}"
          erase_transition(transition) if transition
        end

        def space_features_erased(entity)
          @primal_group = nil if entity == @primal_group
          @dual_group = nil if entity == @dual_group
          @space_features_observed_ids.delete(entity.object_id)
          @scene_group_guard.untrack(entity)
        rescue StandardError
          nil
        end

        private

        def bind_registry_collections
          @cell_spaces = @feature_registry.cell_spaces
          @states = @feature_registry.states
          @transitions = @feature_registry.transitions
          @doors = @feature_registry.doors
          @transfer_spaces = @feature_registry.transfer_spaces
          @adjacent_cell_space_pairs = @feature_registry.adjacent_cell_space_pairs
          @transitions_by_cell_pair = @feature_registry.transitions_by_cell_pair
        end

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

        def find_existing_space_features_groups
          entities = Sketchup.active_model.entities
          @primal_group = find_group(entities, PRIMAL_GROUP_NAME)
          @dual_group = find_group(entities, DUAL_GROUP_NAME)
          puts '[IndoorGML] PrimalSpaceFeatures group not found during refresh.' unless @primal_group&.valid?
          puts '[IndoorGML] DualSpaceFeatures group not found during refresh.' unless @dual_group&.valid?
        end

        def attach_existing_space_features_observers
          attach_entities_observer(:root, Sketchup.active_model.entities, @root_entities_observer)
          attach_existing_space_features_observer(@primal_group, PRIMAL_GROUP_NAME)
          attach_existing_space_features_observer(@dual_group, DUAL_GROUP_NAME)
          attach_entities_observer(:primal, @primal_group.entities, @primal_entities_observer) if @primal_group&.valid?
          attach_entities_observer(:dual, @dual_group.entities, @dual_entities_observer) if @dual_group&.valid?
        end

        def attach_existing_space_features_observer(group, expected_name)
          return unless group&.valid?

          observer_key = group.object_id
          @scene_group_guard.track(group, expected_name)
          return if @space_features_observed_ids[observer_key]

          group.add_observer(@space_features_observer)
          @space_features_observed_ids[observer_key] = true
        end

        def reset_runtime_collections
          @feature_registry.reset!
          bind_registry_collections
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

          observer_key = group.object_id
          @scene_group_guard.track(group, expected_name)
          with_unlocked(group) { group.name = expected_name } unless group.name == expected_name
          return if @space_features_observed_ids[observer_key]

          group.add_observer(@space_features_observer)
          @space_features_observed_ids[observer_key] = true
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
          @attribute_serializer.write_space_features(group, feature)
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
          @scene_group_guard.enforce(ordered_space_features_groups)
        end

        def ordered_space_features_groups
          [@primal_group, @dual_group].compact
        end

        def restore_space_features_name(group)
          expected_name = nil
          return if expected_name.nil? || group.name == expected_name

          UI.messagebox('이름을 변경할 수 없는 Group입니다.')
          with_unlocked(group) { group.name = expected_name }
        end

        def restore_space_features_scale(group)
          return false unless Utils::Transformation.scaled?(group.transformation)

          UI.messagebox('크기를 조절할 수 없는 Group입니다.')
          set_group_transformation(group, Geom::Transformation.new)
          true
        end

        def synchronize_space_features_from(source_group)
          @scene_group_guard.synchronize_from(source_group, ordered_space_features_groups)
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
          @feature_registry.add_cell_space(cell_space)
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
          @feature_registry.add_cell_space_type_reference(cell_space)
        end

        def remove_cell_space_from_type_runtime_lists(cell_space)
          @feature_registry.remove_cell_space_type_reference(cell_space)
        end

        def register_state(state)
          @feature_registry.add_state(state)
          attach_state_observer(state.sketchup_component_instance)
          lock_indoor_entity(state.sketchup_component_instance)
        end

        def unregister_cell_space(cell_space)
          return if cell_space.nil?

          @feature_registry.remove_cell_space(cell_space)
          @cell_space_observed_ids.delete(cell_space.sketchup_group.object_id)
        end

        def unregister_state(state)
          return if state.nil?

          @feature_registry.remove_state(state)
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
              @dual_group.entities,
              cell1: cell1,
              cell2: cell2
            )
            @feature_registry.add_transition(transition, pair_key: pair_key)
          end

          return nil unless update_transition(transition)

          register_transition_with_states(transition)
          register_transition_entity(transition)
          write_transition_attributes(transition)
          lock_indoor_entity(transition.edge)
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

          unregister_transition_entity(transition)
          unregister_transition_from_states(transition)
          unlock_indoor_entity(transition.edge)
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

        def restore_transition_with_states(transition)
          transition.state1.add_transition(transition)
          transition.state2.add_transition(transition)
        end

        def register_transition_entity(transition)
          return unless transition&.edge&.valid?

          @feature_registry.register_transition_entity(transition)
        end

        def unregister_transition_entity(transition)
          return if transition.nil?

          @feature_registry.unregister_transition_entity(transition)
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

            if transition.cell1 && transition.cell2
              pair_key = cell_pair_key(transition.cell1, transition.cell2)
              @feature_registry.delete_transition_for_pair(pair_key)
              @feature_registry.delete_adjacent_pair(pair_key)
            end
            erase_transition(transition)
            true
          end
        end

        def write_attributes(cell_space)
          @attribute_serializer.write_cell_space_and_state(cell_space)
          group = cell_space.sketchup_group
          state = cell_space.duality_state.sketchup_component_instance
          lock_indoor_entity(group)
          lock_indoor_entity(state)
        end

        def write_cell_space_attributes(cell_space)
          @attribute_serializer.write_cell_space(cell_space)
          lock_indoor_entity(cell_space.sketchup_group)
        end

        def write_state_attributes(state)
          @attribute_serializer.write_state(state)
          lock_indoor_entity(state.sketchup_component_instance) if state&.valid?
        end

        def write_transition_attributes(transition)
          @attribute_serializer.write_transition(transition)
          lock_indoor_entity(transition.edge) if transition&.edge&.valid?
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
          @attribute_serializer.indoor_gml_entity?(entity)
        end

        def indoor_attribute(entity, key)
          @attribute_serializer.attribute(entity, key)
        end

        def indoor_feature(entity)
          @attribute_serializer.feature(entity)
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
          @attribute_serializer.copy_indoor_attributes(source, target)
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
          @attribute_serializer.converted_group?(sketchup_group)
        end

        def find_cell_space_for_entity(entity)
          @feature_registry.find_cell_space_for_entity(entity)
        end

        def find_state_for_entity(entity)
          @feature_registry.find_state_for_entity(entity)
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
