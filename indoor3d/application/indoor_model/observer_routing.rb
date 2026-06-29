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
            when :transform
              handle_space_features_transform_changed(entity)
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
            return nil if changed_fields.empty?

            change_kind =
              if changed_fields.include?(:name)
                :name
              elsif changed_fields.include?(:transformation)
                :transform
              else
                :etc
              end
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
          end

          def handle_space_features_transform_changed(entity)
            invalidate_overlay_transition_points
            remember_space_features_change_snapshot(entity)
            Sketchup.active_model&.active_view&.invalidate
            true
          end

          def handle_space_features_etc_changed(entity)
            IndoorCore::Logger.puts "[IndoorGML] SpaceFeatures change ignored as etc: entity_id=#{entity.entityID} name=#{entity.name}"
            remember_space_features_change_snapshot(entity)
            false
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
              transformation: entity.transformation.to_a
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
        end
      end
    end
  end
end
