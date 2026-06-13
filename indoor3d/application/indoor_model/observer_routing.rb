# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module ObserverRouting
          def space_features_changed(entity)
            return false if guard_active?(:@constraining_space_features) || guard_active?(:@erasing) || @finishing_editing
            return false unless entity&.valid?

            change_kind = classify_space_features_change(entity)
            return false if change_kind.nil?

            case change_kind
            when :name
              handle_space_features_name_changed(entity)
            else
              handle_space_features_etc_changed(entity)
            end
          end

          def classify_space_features_change(entity)
            previous_snapshot = space_features_change_snapshot_for(entity)
            current_snapshot = build_space_features_change_snapshot(entity)
            remember_space_features_change_snapshot(entity, current_snapshot)
            if previous_snapshot.nil?
              expected_name = expected_space_features_name_for(entity)
              if expected_name && current_snapshot[:name] != expected_name
                log_space_features_change(entity, :name, [:name], { name: expected_name }, current_snapshot)
                return :name
              end

              log_space_features_change(entity, :initial_snapshot, [], previous_snapshot, current_snapshot)
              return nil
            end

            changed_fields = changed_space_features_snapshot_fields(previous_snapshot, current_snapshot)
            change_kind = changed_fields.include?(:name) ? :name : :etc
            log_space_features_change(entity, change_kind, changed_fields, previous_snapshot, current_snapshot)
            change_kind
          end

          def handle_space_features_name_changed(entity)
            with_transparent_space_features_operation('IndoorGML SpaceFeatures Name Change') do
              with_guard_flag(:@constraining_space_features) do
                enforce_space_features_constraints()
              end
            end
            remember_space_features_change_snapshot(entity)
            true
          ensure
            with_indoor_model_operation('IndoorGML SpaceFeatures Lock', transparent: true) do
              apply_indoor_lock_policy if entity&.valid?
            end
          end

          def handle_space_features_etc_changed(entity)
            IndoorCore::Logger.puts "[IndoorGML] SpaceFeatures change ignored as etc: entity_id=#{entity.entityID} name=#{entity.name}"
            remember_space_features_change_snapshot(entity)
            false
          ensure
            with_indoor_model_operation('IndoorGML SpaceFeatures Lock', transparent: true) do
              apply_indoor_lock_policy if entity&.valid?
            end
          end

          def with_transparent_space_features_operation(name)
            with_indoor_model_operation(name, transparent: true) { yield }
          end

          def remember_space_features_change_snapshot(entity, snapshot = nil)
            return unless entity&.valid?

            @space_features_change_snapshots[entity_observer_key(entity)] = snapshot || build_space_features_change_snapshot(entity)
          rescue StandardError
            nil
          end

          def space_features_change_snapshot_for(entity)
            @space_features_change_snapshots[entity_observer_key(entity)]
          rescue StandardError
            nil
          end

          def build_space_features_change_snapshot(entity)
            {
              name: entity.name.to_s,
              transformation: entity.transformation.to_a,
              locked: entity.locked? == true
            }
          end

          def changed_space_features_snapshot_fields(previous_snapshot, current_snapshot)
            current_snapshot.keys.select do |key|
              Utils::ChangeSnapshot.field_changed?(key, previous_snapshot[key], current_snapshot[key])
            end
          end

          def log_space_features_change(entity, change_kind, changed_fields, previous_snapshot, current_snapshot)
            IndoorCore::Logger.puts "[IndoorGML] SpaceFeatures change classified kind=#{change_kind} entity_id=#{entity.entityID} name=#{entity.name} fields=#{changed_fields.join(',')}"
            changed_fields.each do |field|
              IndoorCore::Logger.puts "[IndoorGML]   #{field}: #{Utils::ChangeSnapshot.log_value(previous_snapshot&.[](field))} -> #{Utils::ChangeSnapshot.log_value(current_snapshot&.[](field))}"
            end
          end

          def root_entity_added(entity)
            return if @relocating_entity
            return unless indoor_gml_entity?(entity)

            feature = indoor_feature(entity)
            if space_features_feature?(feature)
              with_indoor_model_operation('IndoorGML SpaceFeatures Restore', transparent: true) do
                register_space_features_entity(entity, feature)
              end
              return
            end

            ensure_space_features_groups(transparent: true)
            case feature
            when 'CellSpace'
              relocate_indoor_entity(entity, @primal_group.entities, @primal_group, transparent: true)
            else
              with_indoor_model_operation('IndoorGML Lock Indoor Entity', transparent: true) do
                lock_indoor_entity(entity)
              end
            end
          end

          def root_entity_removed(entity_id)
            return if @erasing || @relocating_entity

            IndoorCore::Logger.puts "[IndoorGML] Root entity removed: entity_id=#{entity_id}"
          end

          def primal_entity_added(entity)
            return if @relocating_entity
            unless indoor_gml_entity?(entity)
              return
            end

            ensure_space_features_groups(transparent: true)
            if indoor_feature(entity) == 'CellSpace'
              with_indoor_model_operation('IndoorGML Primal CellSpace Added', transparent: true) do
                if duplicate_cell_space_identity?(entity)
                  next if make_cell_space_copy_independent(entity)

                  IndoorCore::Logger.puts '[IndoorGML] CellSpace copy independence failed. Falling back to normal add handling.'
                end

                cell_space = find_cell_space_for_entity(entity)
                attach_cell_space_observer(entity)
                if stale_cell_space_runtime?(cell_space, entity)
                  IndoorCore::Logger.puts '[IndoorGML] CellSpace runtime stale. Refreshing runtime data.'
                  refresh_runtime_data
                elsif cell_space
                  synchronize_adjacency_and_transitions_for_cell_space(cell_space)
                else
                  IndoorCore::Logger.puts '[IndoorGML] CellSpace runtime data missing. Refresh is required.'
                end
              end
            else
              relocate_indoor_entity(entity, Sketchup.active_model.entities, transparent: true)
            end
          end

          def primal_entity_removed(entity_id)
            return if @erasing || @relocating_entity

            cell_space = @feature_registry.find_cell_space_by_removed_entity_id(entity_id)
            IndoorCore::Logger.puts "[IndoorGML] Primal entity removed: entity_id=#{entity_id} cell_space=#{cell_space&.id || 'missing'}"
            with_indoor_model_operation('IndoorGML Primal CellSpace Removed', transparent: true) do
              erase_cell_space(cell_space, erase_sketchup_group: false) if cell_space
            end
          end

          def space_features_erased(entity)
            begin
              @primal_group = nil if entity == @primal_group
              delete_entity_observer_key(@space_features_observed_ids, entity)
              @scene_group_guard.untrack(entity)
            rescue StandardError
              nil
            end
          end

          def normalize_primal_children_for_finish
            return unless @primal_group&.valid?

            with_indoor_model_operation('IndoorGML Normalize Primal Children On Finish', transparent: true) do
              begin
                @relocating_entity = true
                raw_entities = []
                @primal_group.entities.to_a.each do |entity|
                  normalize_primal_child_for_finish(entity, raw_entities)
                end
                move_raw_primal_entities_to_root(raw_entities)
              ensure
                @relocating_entity = false
              end
              refresh_runtime_data
              Sketchup.active_model.active_view.invalidate if Sketchup.active_model&.active_view
            end
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Primal children finish normalize failed: #{e.class}: #{e.message}"
          end

          def normalize_primal_child_for_finish(entity, raw_entities)
            return unless entity&.valid?
            return if space_features_origin_point?(entity)
            return if indoor_feature(entity) == 'CellSpace'

            if entity.respond_to?(:definition) && entity.respond_to?(:transformation)
              normalize_primal_container_without_operation(entity)
            else
              raw_entities << entity
            end
          end

          def normalize_primal_container_without_operation(container)
            nested_cell_space_entities(container).each do |entry|
              copy_nested_cell_space_to_primal(entry[:entity], entry[:transformation])
            end
            cleanup_or_move_primal_container(container)
          end

          def nested_cell_space_entities(container, parent_transformation = nil)
            return [] unless container&.valid?
            return [] unless container.respond_to?(:definition) && container.respond_to?(:transformation)

            accumulated = (parent_transformation || Geom::Transformation.new) * container.transformation
            container.definition.entities.to_a.flat_map do |child|
              next [] unless child&.valid?

              if indoor_feature(child) == 'CellSpace'
                [{ entity: child, transformation: accumulated * child.transformation }]
              elsif child.respond_to?(:definition) && child.respond_to?(:transformation)
                nested_cell_space_entities(child, accumulated)
              else
                []
              end
            end
          end

          def copy_nested_cell_space_to_primal(entity, local_transformation)
            copy = @primal_group.entities.add_instance(entity.definition, local_transformation)
            copy = copy.to_group if entity.is_a?(Sketchup::Group) && copy.respond_to?(:to_group)
            copy.make_unique if entity.is_a?(Sketchup::Group) && copy.respond_to?(:make_unique)
            copy.name = entity.name if copy.respond_to?(:name=) && entity.respond_to?(:name)
            copy.material = entity.material if copy.respond_to?(:material=) && entity.respond_to?(:material)
            copy_indoor_attributes(entity, copy)
            entity.erase! if entity.valid?
            copy
          end

          def cleanup_or_move_primal_container(container)
            return unless container&.valid?

            if container.respond_to?(:definition) && container.definition.entities.to_a.empty?
              container.erase!
            else
              move_remaining_primal_container_to_root(container)
            end
          end

          def move_remaining_primal_container_to_root(container)
            return unless container&.valid?
            return unless container.respond_to?(:definition) && container.respond_to?(:transformation)
            return unless primal_direct_container?(container)

            model = Sketchup.active_model
            copy = model.entities.add_instance(container.definition, @primal_group.transformation * container.transformation)
            copy = copy.to_group if container.is_a?(Sketchup::Group) && copy.respond_to?(:to_group)
            copy.make_unique if container.is_a?(Sketchup::Group) && copy.respond_to?(:make_unique)
            copy.name = container.name if copy.respond_to?(:name=) && container.respond_to?(:name)
            copy.material = container.material if copy.respond_to?(:material=) && container.respond_to?(:material)
            copy.layer = container.layer if copy.respond_to?(:layer=) && container.respond_to?(:layer)
            copy.visible = container.visible? if copy.respond_to?(:visible=) && container.respond_to?(:visible?)
            container.erase! if container.valid?
            copy
          end

          def move_raw_primal_entities_to_root(entities)
            raw_entities = Array(entities).select { |entity| entity&.valid? }
            return if raw_entities.empty?
            return unless @primal_group&.valid?

            wrapper = @primal_group.entities.add_group(raw_entities)
            return unless wrapper&.valid?
            if wrapper.entities.to_a.empty?
              wrapper.erase!
              return
            end

            wrapper.name = 'IndoorGML_NonCellSpaceEntities' if wrapper.respond_to?(:name=)
            move_remaining_primal_container_to_root(wrapper)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Raw primal entities relocate failed: #{e.class}: #{e.message}"
            nil
          end

          def space_features_origin_point?(entity)
            return false unless entity.is_a?(Sketchup::ConstructionPoint)

            entity.position.distance(ORIGIN) <= 0.001
          rescue StandardError
            false
          end

          def primal_direct_container?(entity)
            return false unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            return false unless @primal_group&.valid?

            Utils::Transformation.direct_child_of_root?(entity, @primal_group)
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
