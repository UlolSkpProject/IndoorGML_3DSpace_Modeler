# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module SceneGroups
          STATE_FIXED_HEIGHT_OFFSET = 1000.mm unless const_defined?(:STATE_FIXED_HEIGHT_OFFSET, false)

          private

          def ensure_space_features_groups(transparent: false)
            with_indoor_model_operation('IndoorGML Ensure SpaceFeatures Groups', transparent: transparent) do
              Utils::Materials.ensure_all()

              entities = (@model || Sketchup.active_model).entities
              @primal_group = find_group(entities, PRIMAL_GROUP_NAME)
              unless @primal_group&.valid?
                @primal_group = entities.add_group
                @primal_group.name = PRIMAL_GROUP_NAME
              end
              ensure_primal_group_world_aligned
              attach_space_features_observer(@primal_group, PRIMAL_GROUP_NAME)
              write_space_features_attributes(@primal_group, PRIMAL_GROUP_FEATURE)
              ensure_space_features_origin_point(@primal_group)
              attach_entities_observers
              lock_space_features_groups
            end
          end

          def find_existing_space_features_groups
            entities = (@model || Sketchup.active_model).entities
            @primal_group = find_group(entities, PRIMAL_GROUP_NAME)
            ensure_primal_group_world_aligned
            IndoorCore::Logger.puts '[IndoorGML] PrimalSpaceFeatures group not found during refresh.' unless @primal_group&.valid?
          end

          def attach_existing_space_features_observers
            model = @model || Sketchup.active_model
            attach_entities_observer(:root, model.entities, @root_entities_observer)
            attach_existing_space_features_observer(@primal_group, PRIMAL_GROUP_NAME)
            @root_entities_observer.track_entity(@primal_group)
            attach_entities_observer(:primal, @primal_group.entities, @primal_entities_observer) if @primal_group&.valid?
            @primal_entities_observer.track_entities(@primal_group.entities) if @primal_group&.valid?
          end

          def attach_existing_space_features_observer(group, expected_name)
            return unless group&.valid?

            observer_key = entity_observer_key(group)
            @scene_group_guard.track(group, expected_name)
            remember_space_features_change_snapshot(group)
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

            nil
          end

          def place_cell_group(sketchup_group)
            return sketchup_group if inside_primal_group?(sketchup_group)

            raise ArgumentError, 'IndoorGML_PrimalSpaceFeatures is not ready' unless @primal_group&.valid?

            clone_group_under_primal_space(sketchup_group)
          end

          def clone_group_under_primal_space(sketchup_group)
            local_transformation = @primal_group.transformation.inverse * Utils::Transformation.entity_transformation_in_active_context(sketchup_group)
            cell_space_entity = @primal_group.entities.add_instance(sketchup_group.definition, local_transformation)
            raise ArgumentError, 'Could not create CellSpace entity' unless cell_space_entity&.valid?

            cell_space_entity = cell_space_entity.to_group if cell_space_entity.respond_to?(:to_group)
            cell_space_entity.make_unique if cell_space_entity.respond_to?(:make_unique)

            sketchup_group.erase! if sketchup_group.valid?
            cell_space_entity
          end

          def recenter_cell_space_geometry(cell_space_entity, fixed_z_offset_from_bottom: nil)
            with_indoor_model_operation('IndoorGML Recenter CellSpace Geometry', transparent: true) do
              fixed_z = fixed_z_offset_from_bottom.nil? ? nil : fixed_local_z_from_world_offset(cell_space_entity, fixed_z_offset_from_bottom)
              center = Utils::Geometry.find_shell_inner_centroid(cell_space_entity, fixed_z: fixed_z)
              IndoorCore::Logger.puts "[IndoorGML] recenter_cell_space_geometry center=#{center} distance=#{center.distance(ORIGIN)}"
              next if center.distance(ORIGIN) <= 0.001

              set_group_transformation(
                cell_space_entity,
                cell_space_entity.transformation * Geom::Transformation.translation(center)
              )
              cell_space_entity.definition.entities.transform_entities(
                Geom::Transformation.translation(center.vector_to(ORIGIN)),
                cell_space_entity.definition.entities.to_a
              )
            end
          end

          def fixed_local_z_from_world_offset(cell_space_entity, offset_from_world_bottom)
            bounds = cell_space_entity.definition.bounds
            transform = cell_space_entity.transformation
            world_min_z = bounds_corners(bounds).map { |point| point.transform(transform).z }.min
            world_target = Geom::Point3d.new(transform.origin.x, transform.origin.y, world_min_z + offset_from_world_bottom)
            world_target.transform(transform.inverse).z
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] fixed local z from world offset failed: #{e.class}: #{e.message}"
            cell_space_entity.definition.bounds.min.z + offset_from_world_bottom
          end

          def bounds_corners(bounds)
            min = bounds.min
            max = bounds.max
            [
              Geom::Point3d.new(min.x, min.y, min.z),
              Geom::Point3d.new(min.x, min.y, max.z),
              Geom::Point3d.new(min.x, max.y, min.z),
              Geom::Point3d.new(min.x, max.y, max.z),
              Geom::Point3d.new(max.x, min.y, min.z),
              Geom::Point3d.new(max.x, min.y, max.z),
              Geom::Point3d.new(max.x, max.y, min.z),
              Geom::Point3d.new(max.x, max.y, max.z)
            ]
          end

          def recenter_cell_space_origin(cell_space)
            return unless cell_space&.valid?

            ensure_cell_space_is_child_of_primal_space!(cell_space)
            recenter_cell_space_geometry(
              cell_space.sketchup_group,
              fixed_z_offset_from_bottom: fixed_state_height_offset(cell_space)
            )
          end

          def attach_space_features_observer(group, expected_name)
            return unless group&.valid?

            observer_key = entity_observer_key(group)
            @scene_group_guard.track(group, expected_name)
            with_unlocked(group) { group.name = expected_name } unless group.name == expected_name
            remember_space_features_change_snapshot(group)
            return if @space_features_observed_ids[observer_key]

            group.add_observer(@space_features_observer)
            @space_features_observed_ids[observer_key] = true
          end

          def attach_entities_observers
            model = @model || Sketchup.active_model
            attach_entities_observer(:root, model.entities, @root_entities_observer)
            attach_entities_observer(:primal, @primal_group.entities, @primal_entities_observer) if @primal_group&.valid?
            @root_entities_observer.track_entity(@primal_group)
            @primal_entities_observer.track_entities(@primal_group.entities) if @primal_group&.valid?
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
              IndoorCore::Logger.puts "[IndoorGML] SpaceFeatures restore skipped: #{feature} is #{entity.class}"
              return
            end

            case feature
            when PRIMAL_GROUP_FEATURE
              @primal_group = entity
              ensure_primal_group_world_aligned
              attach_space_features_observer(@primal_group, PRIMAL_GROUP_NAME)
              write_space_features_attributes(@primal_group, PRIMAL_GROUP_FEATURE)
              ensure_space_features_origin_point(@primal_group)
              attach_entities_observer(:primal, @primal_group.entities, @primal_entities_observer)
            end
          end

          def ensure_space_features_origin_point(group)
            begin
              return unless group&.valid?

              point = origin_construction_point(group) || group.entities.add_cpoint(ORIGIN)
              point.hidden = true if point&.valid? && point.respond_to?(:hidden=)
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Origin point creation failed: #{e.class}: #{e.message}"
            end
          end

          def origin_construction_point(group)
            begin
              group.entities.grep(Sketchup::ConstructionPoint).find do |point|
                point.valid? && point.position.distance(ORIGIN) <= 0.001
              end
            rescue StandardError
              nil
            end
          end

          def lock_space_features_groups
            editing? ? unlock_indoor_entity(@primal_group) : lock_indoor_entity(@primal_group)
          end

          def enforce_space_features_constraints
            ensure_space_features_guard_tracking
            ensure_primal_group_world_aligned
            @scene_group_guard.enforce(ordered_space_features_groups)
          end

          def ordered_space_features_groups
            [@primal_group].compact
          end

          def ensure_space_features_guard_tracking
            @scene_group_guard.ensure_expected_name(@primal_group, PRIMAL_GROUP_NAME) if @primal_group&.valid?
          end

          def ensure_primal_group_world_aligned
            return false unless @primal_group&.valid?
            return true if Utils::Transformation.same?(@primal_group.transformation, Geom::Transformation.new)

            absorb_primal_group_transformation
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Primal world alignment failed: #{e.class}: #{e.message}"
            false
          end

          def absorb_primal_group_transformation
            transformation = @primal_group.transformation
            IndoorCore::Logger.puts '[IndoorGML] Primal transform is non-identity; absorbing into children.'
            with_guard_flag(:@constraining_space_features) do
              with_unlocked(@primal_group) do
                @primal_group.entities.to_a.each do |entity|
                  absorb_primal_child_transformation(entity, transformation)
                end
                @primal_group.transformation = Geom::Transformation.new
              end
            end
            remember_space_features_change_snapshot(@primal_group)
            refresh_after_primal_world_alignment
          end

          def absorb_primal_child_transformation(entity, transformation)
            return unless entity&.valid?

            if entity.respond_to?(:transformation) && entity.respond_to?(:transformation=)
              with_unlocked(entity) do
                entity.transformation = transformation * entity.transformation
              end
            else
              @primal_group.entities.transform_entities(transformation, [entity])
            end
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Primal child transform absorption failed: #{e.class}: #{e.message}"
          end

          def refresh_after_primal_world_alignment
            @cell_spaces.each do |cell_space|
              remember_cell_space_change_snapshot(cell_space.sketchup_group) if cell_space&.valid?
            end
            rebuild_runtime_transitions_from_cell_adjacency if @cell_spaces.any?
            invalidate_overlay_transition_points
            (@model || Sketchup.active_model)&.active_view&.invalidate
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Primal world alignment refresh failed: #{e.class}: #{e.message}"
          end

          def expected_space_features_name_for(entity)
            return PRIMAL_GROUP_NAME if entity == @primal_group
            return PRIMAL_GROUP_NAME if indoor_feature(entity) == PRIMAL_GROUP_FEATURE

            nil
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

          def fixed_state_height_offset(cell_space)
            category = cell_space&.category_code.to_s.downcase
            return STATE_FIXED_HEIGHT_OFFSET if category.include?('room') || category.include?('door')

            nil
          end

          def inside_primal_group?(sketchup_group)
            begin
              Utils::Transformation.direct_child_of_root?(sketchup_group, @primal_group)
            rescue StandardError
              false
            end
          end

          def state_local_position(state)
            state.position
          end

          def ensure_cell_space_is_child_of_primal_space!(cell_space)
            Utils::Transformation.ensure_direct_child_of_root!(
              cell_space.sketchup_group,
              @primal_group,
              "[IndoorGML] Coordinate warning: CellSpace #{cell_space.sketchup_group.name} is not a child of #{PRIMAL_GROUP_NAME}"
            )
          end

        end
      end
    end
  end
end
