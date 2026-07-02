# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class OverlayController
          def initialize(indoor_model:, overlay_factory: nil)
            @indoor_model = indoor_model
            @overlay_factory = overlay_factory || proc { EditModeOverlay.new(@indoor_model) }
            @overlay = nil
            @registered = false
            @model = nil
          end

          def ensure_registered(model)
            if @registered && @model == model
              set_enabled(true)
              return
            end
            return unless model.respond_to?(:overlays)

            @overlay ||= @overlay_factory.call
            remove_stale_instances(model)
            model.overlays.add(@overlay)
            @registered = true
            @model = model
            set_enabled(true)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay registration failed: #{e.class}: #{e.message}"
          end

          def set_enabled(enabled)
            return unless @overlay&.valid?

            @overlay.enabled = enabled
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay enable failed: #{e.class}: #{e.message}"
          end

          def update_enabled(editing:, dual_overlay_visible:, progress_active:)
            set_enabled(editing == true || dual_overlay_visible == true || progress_active == true)
          end

          def invalidate_transition_points
            @overlay&.invalidate_transition_points
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay transition cache invalidation failed: #{e.class}: #{e.message}"
          end

          def invalidate_view(model)
            model.active_view.invalidate if model&.active_view
          end

          private

          def remove_stale_instances(model)
            stale_overlays = []
            model.overlays.each do |overlay|
              next unless overlay.overlay_id == EditModeOverlay::OVERLAY_ID
              next if overlay.equal?(@overlay)

              stale_overlays << overlay
            end
            stale_overlays.each { |overlay| model.overlays.remove(overlay) }
          end
        end
      end
    end
  end
end
