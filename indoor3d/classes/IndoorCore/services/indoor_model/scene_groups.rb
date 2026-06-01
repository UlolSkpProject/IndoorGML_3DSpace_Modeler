# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module SceneGroups
          private

          def ensure_space_features_groups
            Utils::Materials.ensure_all

            entities = Sketchup.active_model.active_entities
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
            @root_entities_observer.track_entity(@primal_group)
            @root_entities_observer.track_entity(@dual_group)
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
            return sketchup_group if inside_primal_group?(sketchup_group)

            raise ArgumentError, 'IndoorGML_PrimalSpaceFeatures is not ready' unless @primal_group&.valid?

            clone_group_under_primal_space(sketchup_group)
          end

          def clone_group_under_primal_space(sketchup_group)
            local_transformation = @primal_group.transformation.inverse * Utils::Transformation.entity_world_transformation(sketchup_group)
            cell_space_entity = @primal_group.entities.add_instance(sketchup_group.definition, local_transformation)
            raise ArgumentError, 'Could not create CellSpace entity' unless cell_space_entity&.valid?

            cell_space_entity = cell_space_entity.to_group if cell_space_entity.respond_to?(:to_group)
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

          def ensure_space_features_origin_point(group)
            begin
              return unless group&.valid?
              return if origin_construction_point?(group)

              group.entities.add_cpoint(ORIGIN)
            rescue StandardError => e
              puts "[IndoorGML] Origin point creation failed: #{e.class}: #{e.message}"
            end
          end

          def origin_construction_point?(group)
            begin
              group.entities.grep(Sketchup::ConstructionPoint).any? do |point|
                point.valid? && point.position.distance(ORIGIN) <= 0.001
              end
            rescue StandardError
              false
            end
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
            begin
              Utils::Transformation.direct_child_of_root?(sketchup_group, @primal_group)
            rescue StandardError
              false
            end
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
        end
      end
    end
  end
end
