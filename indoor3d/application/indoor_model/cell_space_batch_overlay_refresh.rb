# frozen_string_literal: true

require_relative 'cell_space_type_change_optimization'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      if defined?(EditorSession)
        class EditorSession
          # Refreshes the runtime display after a successful CellSpace batch without
          # persisting the already-loaded display preference again. Persisting the
          # same graph_visible value after the conversion operation commits creates
          # SketchUp's implicit "Properties" Undo item.
          module CellSpaceBatchDisplayRefresh
            def refresh_display_state_after_bulk_conversion
              model = Sketchup.active_model()
              ensure_overlay_registered(model) if dual_overlay_visible?
              update_overlay_enabled()
              apply_current_geometry_visibility()
              true
            rescue StandardError => e
              if defined?(IndoorCore::Logger)
                IndoorCore::Logger.puts(
                  "[IndoorGML] Bulk display state refresh failed: #{e.class}: #{e.message}"
                )
              end
              false
            end
          end

          prepend CellSpaceBatchDisplayRefresh unless ancestors.include?(CellSpaceBatchDisplayRefresh)
        end
      end

      class IndoorModel
        # Ensures the dual-graph overlay is usable after a successful outermost
        # CellSpace batch mutation. State/Transition creation can invalidate an
        # existing overlay cache, but a source model without IndoorGML runtime
        # data may not have registered its overlay yet. In that case cache
        # invalidation alone is a no-op and the newly-created graph is invisible.
        module CellSpaceBatchOverlayRefresh
          private

          def with_bulk_cell_space_conversion
            outermost_batch = !guard_active?(:@bulk_cell_space_conversion)
            result = super
            refresh_dual_overlay_after_bulk_conversion if outermost_batch
            result
          end

          def refresh_dual_overlay_after_bulk_conversion
            model = @model || active_sketchup_model
            active_model = active_sketchup_model
            return true unless model
            return true if active_model && !active_model.equal?(model)

            session = @editor_session
            return true unless session

            # This refresh must not call apply_display_state. That API persists the
            # current graph_visible preference through Model#set_attribute and, when
            # called after the conversion commit, creates a separate Properties Undo.
            if session.respond_to?(:refresh_display_state_after_bulk_conversion)
              session.refresh_display_state_after_bulk_conversion
            elsif session.respond_to?(:apply_current_geometry_visibility)
              # Safe load-order fallback: preserve geometry visibility without
              # writing model attributes. Overlay registration is retried on the
              # next normal display-state lifecycle.
              session.apply_current_geometry_visibility
            end

            if session.respond_to?(:invalidate_overlay_transition_points)
              session.invalidate_overlay_transition_points
            end
            model.active_view.invalidate if model.respond_to?(:active_view) && model.active_view
            true
          rescue StandardError => e
            if defined?(IndoorCore::Logger)
              IndoorCore::Logger.puts(
                "[IndoorGML] Bulk dual overlay refresh failed: #{e.class}: #{e.message}"
              )
            end
            false
          end

          def active_sketchup_model
            return nil unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

            Sketchup.active_model
          rescue StandardError
            nil
          end
        end

        prepend CellSpaceBatchOverlayRefresh unless ancestors.include?(CellSpaceBatchOverlayRefresh)
      end
    end
  end
end
