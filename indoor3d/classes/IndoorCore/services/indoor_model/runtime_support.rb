# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module RuntimeSupport
          def refresh_runtime_data
            begin
              return true if @refreshing_runtime

              @refreshing_runtime = true
              sync do
                @model = Sketchup.active_model
                find_existing_space_features_groups
                attach_existing_space_features_observers
                reset_runtime_collections
                @runtime_restorer.restore(primal_group: @primal_group, dual_group: @dual_group)
              end
              apply_indoor_lock_policy()
              puts "[IndoorGML] Runtime refreshed: cells=#{@cell_spaces.length}, states=#{@states.length}, transitions=#{@transitions.length}"
              true
            ensure
              @refreshing_runtime = false
            end
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

          def reset_runtime_collections
            @feature_registry.reset!
            bind_registry_collections
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

          def stale_state_runtime?(state, entity)
            begin
              return true if state.nil?
              return true unless state.valid?
              return true unless state.sketchup_component_instance == entity
              return true unless state.duality_cell&.valid?

              false
            rescue StandardError
              true
            end
          end

          def refresh_and_find_cell_space(entity)
            refresh_runtime_data
            find_cell_space_for_entity(entity)
          end

          def refresh_and_find_state(entity)
            refresh_runtime_data
            find_state_for_entity(entity)
          end

          def write_space_features_attributes(group, feature)
            @attribute_serializer.write_space_features(group, feature)
          end

          def write_attributes(cell_space)
            @attribute_serializer.write_cell_space_and_state(cell_space)
            lock_indoor_entity(cell_space.sketchup_group)
            lock_indoor_entity(cell_space.duality_state.sketchup_component_instance)
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

          def converted_group?(sketchup_group)
            @attribute_serializer.converted_group?(sketchup_group)
          end

          def find_cell_space_for_entity(entity)
            @feature_registry.find_cell_space_for_entity(entity)
          end

          def find_state_for_entity(entity)
            @feature_registry.find_state_for_entity(entity)
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
            begin
              @syncing = true
              yield
            ensure
              @syncing = false
            end
          end

          def erase_guard
            begin
              @erasing = true
              yield
            ensure
              @erasing = false
            end
          end
        end
      end
    end
  end
end
