# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        # Runtime refresh policy for Local Grid V2.
        #
        # Hard refresh is the only whole-model refresh allowed to mutate CellSpace
        # coordinate frames. Soft refresh rebuilds runtime/topology state without
        # touching CellSpace local axes, local vertices, or origins.
        #
        # LVN is intentionally treated as an external service contract here. This
        # module uses only LocalVertexNormalizer.normalize and .normalized?.
        module LocalGridRefreshPolicyV2
          def refresh_runtime_data(initial_model_load: false)
            if initial_model_load
              enable_local_grid_coordinate_v2!
              return hard_refresh_runtime_data_local_grid_v2(initial_model_load: true)
            end

            return soft_refresh_runtime_data_local_grid_v2 if local_grid_coordinate_v2_enabled?

            super
          end

          # Backward-compatible V2 entrypoint. Initial model load is hard; every
          # other V2 refresh is soft unless the caller explicitly requests hard.
          def refresh_runtime_data_local_grid_v2(initial_model_load: false)
            enable_local_grid_coordinate_v2!
            return hard_refresh_runtime_data_local_grid_v2(initial_model_load: true) if initial_model_load

            soft_refresh_runtime_data_local_grid_v2
          end

          def hard_refresh_runtime_data_local_grid_v2(initial_model_load: false)
            enable_local_grid_coordinate_v2!

            with_indoor_model_operation('IndoorGML Hard Refresh Runtime Data Local Grid V2', transparent: true) do
              next true if guard_active?(:@refreshing_runtime)

              with_guard_flag(:@refreshing_runtime) do
                sync do
                  prepare_primal_children_for_initial_load if initial_model_load
                  restore_runtime_from_current_model(persist_repaired_ids: true)
                  hard_refresh_runtime_cell_spaces_local_grid_v2
                  apply_initial_cell_space_materials if initial_model_load
                  rebuild_runtime_transitions_from_cell_adjacency
                end
                invalidate_overlay_transition_points
                apply_indoor_lock_policy
                @editor_session.apply_display_state
                IndoorCore::Logger.puts(
                  '[IndoorGML] Runtime hard-refreshed Local Grid V2: ' \
                  "cells=#{@cell_spaces.length}, states=#{@states.length}, transitions=#{@transitions.length}"
                )
                true
              end
            end
          end

          def soft_refresh_runtime_data_local_grid_v2
            enable_local_grid_coordinate_v2!

            with_indoor_model_operation('IndoorGML Soft Refresh Runtime Data Local Grid V2', transparent: true) do
              next true if guard_active?(:@refreshing_runtime)

              with_guard_flag(:@refreshing_runtime) do
                sync do
                  restore_runtime_from_current_model(persist_repaired_ids: true)
                  rebuild_runtime_transitions_from_cell_adjacency
                end
                invalidate_overlay_transition_points
                apply_indoor_lock_policy
                @editor_session.apply_display_state
                IndoorCore::Logger.puts(
                  '[IndoorGML] Runtime soft-refreshed Local Grid V2: ' \
                  "cells=#{@cell_spaces.length}, states=#{@states.length}, transitions=#{@transitions.length}"
                )
                true
              end
            end
          end

          # V2 geometry-close policy:
          #   one CellSpace only
          #   axis evaluation/alignment -> public LVN normalize -> snapped recenter
          # Runtime recovery inside this path is always soft.
          def cell_space_closed(entity)
            return super unless local_grid_coordinate_v2_enabled?
            return if observer_routing_suppressed? || @syncing || @erasing

            cell_space = find_cell_space_for_entity(entity)
            if stale_cell_space_runtime?(cell_space, entity)
              soft_refresh_runtime_data_local_grid_v2
              cell_space = find_cell_space_for_entity(entity)
            end
            return if cell_space.nil? || !cell_space.valid?

            with_transparent_cell_space_operation('IndoorGML CellSpace Geometry Close Local Grid V2') do
              sync do
                finish_cell_space_geometry_local_grid_v2(cell_space)
                name_cell_space_entity(cell_space)
                apply_cell_space_material(cell_space)

                state = cell_space.duality_state
                unless state&.valid?
                  soft_refresh_runtime_data_local_grid_v2
                  cell_space = find_cell_space_for_entity(entity)
                end

                mark_cell_space_dirty(cell_space)
              end
            end
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
          end

          # Overall Edit Mode finish must not perform a whole-model axis pass. Any
          # edited CellSpace has already been finalized by cell_space_closed.
          def finish_editing
            return super unless local_grid_coordinate_v2_enabled?
            return false if validation_focus_recheck_running?

            with_guard_flag(:@finishing_editing) do
              finished = @editor_session.finish()
              if finished
                normalize_primal_children_for_finish()
                soft_refresh_runtime_data_local_grid_v2
              end
              finished
            end
          end

          private

          def hard_refresh_runtime_cell_spaces_local_grid_v2
            @cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              hard_refresh_cell_space_coordinates_local_grid_v2(cell_space)
              write_cell_space_attributes(cell_space)
            rescue StandardError => e
              IndoorCore::Logger.puts(
                '[IndoorGML] Runtime CellSpace Local Grid V2 hard refresh skipped: ' \
                "cell=#{cell_space&.id} #{e.class}: #{e.message}"
              )
            end
          end

          def hard_refresh_cell_space_coordinates_local_grid_v2(cell_space)
            return false unless cell_space&.valid?

            ensure_cell_space_is_child_of_primal_space!(cell_space)
            group = cell_space.sketchup_group

            normalized_before = LocalVertexNormalizer.normalized?(
              group,
              LOCAL_GRID_V2_TOLERANCE_MM
            )

            frame_report = align_cell_space_local_frame_local_grid_v2(group)
            normalize_reason = if frame_report[:changed]
                                 :hard_refresh_frame_changed
                               elsif !normalized_before
                                 :hard_refresh_not_normalized
                               end

            normalize_cell_space_local_grid_v2!(group, reason: normalize_reason) if normalize_reason

            recenter_report = recenter_cell_space_geometry_local_grid_v2(
              group,
              fixed_z_offset_from_bottom: fixed_state_height_offset(cell_space)
            )

            assert_cell_space_local_grid_v2!(group, context: :hard_refresh)
            log_local_grid_v2_coordinate_report(
              cell_space,
              frame_report,
              recenter_report,
              normalized: true
            )
            true
          end
        end
      end
    end
  end
end
