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
            unless indoor_gml_entity?(entity)
              convert_new_edit_mode_group_to_cell_space(entity)
              return
            end

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

          def space_features_erased(entity)
            begin
              @primal_group = nil if entity == @primal_group
              @space_features_observed_ids.delete(entity.object_id)
              @scene_group_guard.untrack(entity)
            rescue StandardError
              nil
            end
          end

          def convert_new_edit_mode_group_to_cell_space(entity)
            return unless editing?
            return unless convertible_new_cell_space_group?(entity)

            UI.start_timer(0, false) do
              operation_started = false
              begin
                next unless entity&.valid?
                next if indoor_gml_entity?(entity)
                next unless convertible_new_cell_space_group?(entity)

                model = Sketchup.active_model()
                model.start_operation('Convert New Group to GeneralSpace', true)
                operation_started = true
                convert_group_to_cell_space(entity, CellSpaceType::GENERAL)
                model.commit_operation
                operation_started = false
                @editor_session.selection_changed()
                model.active_view.invalidate if model&.active_view
              rescue StandardError => e
                model.abort_operation if operation_started && model
                puts "[IndoorGML] Auto GeneralSpace conversion failed: #{e.class}: #{e.message}"
              end
            end
          end

          def convertible_new_cell_space_group?(entity)
            return false unless entity&.valid?
            return false unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            return false unless entity.respond_to?(:manifold?) && entity.manifold?
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
