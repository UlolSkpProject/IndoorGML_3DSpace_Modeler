# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module LocalGridCoordinate
          unless method_defined?(:convert_cell_space_jobs_bulk_local_grid_without_activation)
            alias_method :convert_cell_space_jobs_bulk_local_grid_without_activation,
                         :convert_cell_space_jobs_bulk_local_grid
          end

          unless method_defined?(:convert_single_group_to_cell_space_local_grid_without_activation)
            alias_method :convert_single_group_to_cell_space_local_grid_without_activation,
                         :convert_single_group_to_cell_space_local_grid
          end

          unless method_defined?(:refresh_runtime_data_local_grid_without_activation)
            alias_method :refresh_runtime_data_local_grid_without_activation,
                         :refresh_runtime_data_local_grid
          end

          def enable_local_grid_coordinate!
            @local_grid_coordinate_enabled = true
            true
          end

          def disable_local_grid_coordinate!
            @local_grid_coordinate_enabled = false
            true
          end

          def local_grid_coordinate_enabled?
            @local_grid_coordinate_enabled == true
          end

          def convert_cell_space_jobs_bulk_local_grid(*args, **kwargs)
            enable_local_grid_coordinate!
            convert_cell_space_jobs_bulk_local_grid_without_activation(*args, **kwargs)
          end

          def convert_single_group_to_cell_space_local_grid(*args, **kwargs)
            enable_local_grid_coordinate!
            convert_single_group_to_cell_space_local_grid_without_activation(*args, **kwargs)
          end

          def refresh_runtime_data_local_grid(initial_model_load: false)
            enable_local_grid_coordinate!
            refresh_runtime_data_local_grid_without_activation(
              initial_model_load: initial_model_load
            )
          end

          # Local-grid mode only. FeatureLifecycle#cell_space_closed remains the
          # compatibility fallback while Local Grid is disabled.
          #
          # Geometry close policy:
          #   frame evaluation/alignment
          #   -> snapped recenter
          #
          # Optional LVN is intentionally excluded and remains console/API opt-in.
          def cell_space_closed(entity)
            return super unless local_grid_coordinate_enabled?
            return if observer_routing_suppressed? || @syncing || @erasing

            cell_space = find_cell_space_for_entity(entity)
            if stale_cell_space_runtime?(cell_space, entity)
              refresh_runtime_data_local_grid
              cell_space = find_cell_space_for_entity(entity)
            end
            return if cell_space.nil? || !cell_space.valid?

            with_transparent_cell_space_operation('IndoorGML CellSpace Geometry Close Local Grid') do
              sync do
                finish_cell_space_geometry_local_grid(cell_space)
                name_cell_space_entity(cell_space)
                apply_cell_space_material(cell_space)

                state = cell_space.duality_state
                unless state&.valid?
                  refresh_runtime_data_local_grid
                  cell_space = find_cell_space_for_entity(entity)
                  state = cell_space&.duality_state
                end

                mark_cell_space_dirty(cell_space)
              end
            end
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
          end

          private

          def finish_cell_space_geometry_local_grid(cell_space)
            group = cell_space.sketchup_group
            ensure_cell_space_is_child_of_primal_space!(cell_space)

            frame_report = align_cell_space_local_frame_local_grid(group)
            recenter_report = recenter_cell_space_geometry_local_grid(
              group,
              fixed_z_offset_from_bottom: fixed_state_height_offset(cell_space)
            )

            log_local_grid_coordinate_report(
              cell_space,
              frame_report,
              recenter_report,
              normalized: :unchecked
            )
            true
          end
        end
      end
    end
  end
end
