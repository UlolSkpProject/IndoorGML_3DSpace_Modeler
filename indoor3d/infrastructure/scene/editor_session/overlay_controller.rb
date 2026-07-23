# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class OverlayController
          LEGACY_EDIT_MODE_OVERLAY_ID = 'ulol.indoor3dgml_modeler.edit_mode_overlay'

          def initialize(
            indoor_model:,
            overlay_factory: nil,
            screen_overlay_factory: nil,
            space_overlay_factory: nil,
            validation_overlay_factory: nil,
            validation_geometry_resolver_factory: nil
          )
            @indoor_model = indoor_model
            @screen_overlay_factory = screen_overlay_factory || overlay_factory || proc { IndoorModeScreenOverlay.new(@indoor_model) }
            @space_overlay_factory = space_overlay_factory || proc { DualGraphSpaceOverlay.new(@indoor_model) }
            @validation_overlay_factory = validation_overlay_factory || proc do
              if defined?(ValidationErrorGeometryOverlay)
                ValidationErrorGeometryOverlay.new(@indoor_model)
              end
            end
            @validation_geometry_resolver_factory = validation_geometry_resolver_factory || proc do
              if defined?(IndoorGmlConverter::ValidationErrorGeometryResolver)
                IndoorGmlConverter::ValidationErrorGeometryResolver.new(
                  indoor_model: @indoor_model
                )
              end
            end
            @screen_overlay = nil
            @space_overlay = nil
            @validation_overlay = nil
            @validation_geometry_resolver = nil
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
            @validation_overlay ||= @validation_overlay_factory.call
            remove_stale_instances(model)
            model.overlays.add(@screen_overlay)
            model.overlays.add(@space_overlay)
            model.overlays.add(@validation_overlay) if @validation_overlay
            @registered = true
            @model = model
            update_enabled_from_model
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay registration failed: #{e.class}: #{e.message}"
          end

          def set_enabled(enabled)
            set_overlay_enabled(@screen_overlay, enabled)
            set_overlay_enabled(@space_overlay, enabled)
            set_overlay_enabled(
              @validation_overlay,
              enabled && validation_focus_active?
            )
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay enable failed: #{e.class}: #{e.message}"
          end

          def update_enabled(editing:, dual_overlay_visible:, progress_active:)
            set_overlay_enabled(@screen_overlay, editing == true)
            set_overlay_enabled(@space_overlay, dual_overlay_visible == true)
            set_overlay_enabled(
              @validation_overlay,
              editing == true && validation_focus_active?
            )
          end

          def set_validation_geometry(row)
            return clear_validation_geometry unless row.is_a?(Hash)

            @validation_geometry_resolver ||= @validation_geometry_resolver_factory.call
            return clear_validation_geometry unless @validation_geometry_resolver

            geometry = @validation_geometry_resolver.resolve(row)
            @validation_overlay&.set_geometry(geometry)
            geometry
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Validation geometry overlay update failed: " \
              "#{e.class}: #{e.message}"
            )
            clear_validation_geometry
          end

          def clear_validation_geometry
            @validation_overlay&.clear
            nil
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Validation geometry overlay clear failed: " \
              "#{e.class}: #{e.message}"
            )
            nil
          end

          def invalidate_validation_geometry_cache
            if @validation_geometry_resolver&.respond_to?(:clear_cache)
              @validation_geometry_resolver.clear_cache
            elsif defined?(IndoorGmlConverter::ValidationErrorGeometryResolver)
              model = @indoor_model.respond_to?(:model) ? @indoor_model.model : nil
              IndoorGmlConverter::ValidationErrorGeometryResolver.clear_overlap_geometry(
                model: model
              ) if model
            end
            true
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Validation geometry overlay cache invalidation failed: " \
              "#{e.class}: #{e.message}"
            )
            false
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
            if defined?(ValidationErrorGeometryOverlay::OVERLAY_ID)
              stale_ids << ValidationErrorGeometryOverlay::OVERLAY_ID
            end
            model.overlays.each do |overlay|
              next unless stale_ids.include?(overlay.overlay_id)
              next if overlay.equal?(@screen_overlay) ||
                      overlay.equal?(@space_overlay) ||
                      overlay.equal?(@validation_overlay)

              stale_overlays << overlay
            end
            stale_overlays.each { |overlay| model.overlays.remove(overlay) }
          end


          def validation_focus_active?
            @indoor_model.respond_to?(:validation_focus_active?) &&
              @indoor_model.validation_focus_active?
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
