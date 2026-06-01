# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module ObserverRouting
          def space_features_changed(entity)
            begin
              return if @constraining_space_features || @erasing
              return unless entity&.valid?

              @constraining_space_features = true
              enforce_space_features_constraints
            ensure
              lock_indoor_entity(entity)
              @constraining_space_features = false
            end
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
            begin
              @primal_group = nil if entity == @primal_group
              @dual_group = nil if entity == @dual_group
              @space_features_observed_ids.delete(entity.object_id)
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
