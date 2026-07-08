# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class OverlayController
          LEGACY_EDIT_MODE_OVERLAY_ID = 'ulol.indoor3dgml_modeler.edit_mode_overlay'

          def initialize(indoor_model:, overlay_factory: nil, screen_overlay_factory: nil, space_overlay_factory: nil)
            @indoor_model = indoor_model
            @screen_overlay_factory = screen_overlay_factory || overlay_factory || proc { IndoorModeScreenOverlay.new(@indoor_model) }
            @space_overlay_factory = space_overlay_factory || proc { DualGraphSpaceOverlay.new(@indoor_model) }
            @screen_overlay = nil
            @space_overlay = nil
            @registered = false
            @model = nil
          end

          def ensure_registered(model)
            if @registered && @model == model
              update_enabled_from_model
              return
            end
            return unless model.respond_to?(:overlays)

            @screen_overlay ||= @screen_overlay_factory.call
            @space_overlay ||= @space_overlay_factory.call
            remove_stale_instances(model)
            model.overlays.add(@screen_overlay)
            model.overlays.add(@space_overlay)
            @registered = true
            @model = model
            update_enabled_from_model
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay registration failed: #{e.class}: #{e.message}"
          end

          def set_enabled(enabled)
            set_overlay_enabled(@screen_overlay, enabled)
            set_overlay_enabled(@space_overlay, enabled)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay enable failed: #{e.class}: #{e.message}"
          end

          def update_enabled(editing:, dual_overlay_visible:, progress_active:)
            set_overlay_enabled(@screen_overlay, editing == true)
            set_overlay_enabled(@space_overlay, dual_overlay_visible == true)
          end

          def invalidate_transition_points
            @space_overlay&.invalidate_transition_points
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay transition cache invalidation failed: #{e.class}: #{e.message}"
          end

          def invalidate_view(model)
            model.active_view.invalidate if model&.active_view
          end

          private

          def update_enabled_from_model
            update_enabled(
              editing: @indoor_model.respond_to?(:editing?) && @indoor_model.editing?,
              dual_overlay_visible: @indoor_model.respond_to?(:dual_overlay_visible?) && @indoor_model.dual_overlay_visible?,
              progress_active: false
            )
          end

          def set_overlay_enabled(overlay, enabled)
            return unless overlay&.valid?

            overlay.enabled = enabled
          end

          def remove_stale_instances(model)
            stale_overlays = []
            stale_ids = [
              IndoorModeScreenOverlay::OVERLAY_ID,
              DualGraphSpaceOverlay::OVERLAY_ID,
              LEGACY_EDIT_MODE_OVERLAY_ID
            ]
            model.overlays.each do |overlay|
              next unless stale_ids.include?(overlay.overlay_id)
              next if overlay.equal?(@screen_overlay) || overlay.equal?(@space_overlay)

              stale_overlays << overlay
            end
            stale_overlays.each { |overlay| model.overlays.remove(overlay) }
          end
        end
      end
    end
  end
end
