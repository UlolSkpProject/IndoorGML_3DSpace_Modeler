# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
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

            # Registration/enabled state must be applied before cache
            # invalidation. Otherwise @space_overlay can still be nil.
            session.apply_display_state if session.respond_to?(:apply_display_state)
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
