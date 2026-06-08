# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module RuntimeSupport
          def refresh_runtime_data
            with_indoor_model_operation('IndoorGML Refresh Runtime Data', transparent: true) do
              next true if @refreshing_runtime

              @refreshing_runtime = true
              sync do
                @model ||= Sketchup.active_model
                find_existing_space_features_groups
                attach_existing_space_features_observers
                reset_runtime_collections
                @runtime_restorer.restore(primal_group: @primal_group)
                rebuild_runtime_transitions_from_cell_adjacency
              end
              apply_indoor_lock_policy()
              puts "[IndoorGML] Runtime refreshed: cells=#{@cell_spaces.length}, states=#{@states.length}, transitions=#{@transitions.length}"
              true
            end
          ensure
            @refreshing_runtime = false
          end

          private

          def with_indoor_model_operation(name, transparent: false)
            return yield if @indoor_operation_depth.to_i.positive?

            model = @model || Sketchup.active_model
            return yield unless model
            if model.respond_to?(:active_operation_name) && model.active_operation_name.to_s.length.positive?
              return yield
            end

            operation_started = false
            @indoor_operation_depth = @indoor_operation_depth.to_i + 1
            begin
              operation_started = model.start_operation(name, true, false, transparent)
              result = yield
              model.commit_operation if operation_started
              operation_started = false
              result
            rescue StandardError
              model.abort_operation if operation_started
              raise
            ensure
              @indoor_operation_depth = [@indoor_operation_depth.to_i - 1, 0].max
            end
          end

          def bind_registry_collections
            @cell_spaces = @feature_registry.cell_spaces
            @states = @feature_registry.states
            @transitions = @feature_registry.transitions
          end

          def reset_runtime_collections
            @feature_registry.reset!
            @cell_space_change_snapshots.clear
            @space_features_change_snapshots.clear
            @dirty_cell_space_pids&.clear
            @cell_space_sync_scheduled = false
            bind_registry_collections
          end

          def clear_indoor_gml_groups
            [@primal_group].each do |group|
              next unless group&.valid?

              unlock_indoor_entity(group)
              group.erase!
            end
            @primal_group = nil
            @cell_space_observed_ids.clear
            @space_features_observed_ids.clear
            @entities_observed_ids.clear
          end

          def stale_cell_space_runtime?(cell_space, entity)
            begin
              return true if cell_space.nil?
              return true unless cell_space.valid?
              return true unless cell_space.sketchup_group == entity
              return true unless cell_space.duality_state&.valid?

              false
            rescue StandardError
              true
            end
          end

          def refresh_and_find_cell_space(entity)
            refresh_runtime_data
            find_cell_space_for_entity(entity)
          end

          def defer_ui_message(message)
            UI.start_timer(0, false) do
              UI.messagebox(message)
            end
          end

          def write_space_features_attributes(group, feature)
            @attribute_serializer.write_space_features(group, feature)
          end

          def write_attributes(cell_space)
            @attribute_serializer.write_cell_space_and_state(cell_space)
            remember_cell_space_change_snapshot(cell_space.sketchup_group) if cell_space&.valid?
          end

          def write_cell_space_attributes(cell_space)
            @attribute_serializer.write_cell_space(cell_space)
            remember_cell_space_change_snapshot(cell_space.sketchup_group) if cell_space&.valid?
          end

          def write_state_attributes(state)
            @attribute_serializer.write_state(state)
          end

          def write_transition_attributes(transition)
            @attribute_serializer.write_transition(transition)
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

          def space_features_feature?(feature)
            feature == PRIMAL_GROUP_FEATURE
          end

          def converted_group?(sketchup_group)
            @attribute_serializer.converted_group?(sketchup_group)
          end

          def find_cell_space_for_entity(entity)
            @feature_registry.find_cell_space_for_entity(entity)
          end

          def with_unlocked(entity)
            @editor_session.with_unlocked(entity) { yield }
          end

          def lock_indoor_entity(entity)
            @editor_session.lock_entity(entity)
          end

          def unlock_indoor_entity(entity)
            @editor_session.unlock_entity(entity)
          end

          def sync
            with_guard_flag(:@syncing) do
              yield
            end
          end

          def erase_guard
            with_guard_flag(:@erasing) do
              yield
            end
          end

          def guard_active?(flag)
            instance_variable_get(flag)
          end

          def with_guard_flag(flag)
            previous_value = instance_variable_get(flag)
            instance_variable_set(flag, true)
            yield
          ensure
            instance_variable_set(flag, previous_value)
          end

          def entity_observer_key(entity)
            return nil unless entity

            entity.object_id
          rescue StandardError
            nil
          end

          def delete_entity_observer_key(observed_ids, entity)
            return unless observed_ids && entity

            observed_ids.delete(entity_observer_key(entity))
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
