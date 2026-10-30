# frozen_string_literal: true

require_relative 'validation_overlay_service'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class OverlayController
          COMPATIBILITY_EDIT_MODE_OVERLAY_ID = 'ulol.indoor3dgml_modeler.edit_mode_overlay'

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
            @validation_overlay_service = nil
            @registered = false
            @model = nil
          end

          def ensure_registered(model)
            if @registered && @model == model
              registered = validation_overlay_service.ensure_registered(model)
              update_enabled_from_model
              return registered
            end
            return unless model.respond_to?(:overlays)

            @screen_overlay ||= @screen_overlay_factory.call
            @space_overlay ||= @space_overlay_factory.call
            remove_stale_instances(model)
            model.overlays.add(@screen_overlay)
            model.overlays.add(@space_overlay)
            @registered = true
            @model = model
            validation_registered = validation_overlay_service.ensure_registered(model)
            update_enabled_from_model
            validation_registered
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay registration failed: #{e.class}: #{e.message}"
          end

          def set_enabled(enabled)
            set_overlay_enabled(@screen_overlay, enabled)
            set_overlay_enabled(@space_overlay, enabled)
            validation_overlay_service.set_enabled(enabled && validation_focus_active?)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay enable failed: #{e.class}: #{e.message}"
            false
          end

          def update_enabled(editing:, dual_overlay_visible:)
            set_overlay_enabled(@screen_overlay, editing == true)
            set_overlay_enabled(@space_overlay, dual_overlay_visible == true)
            validation_overlay_service.set_enabled(editing == true && validation_focus_active?)
          end

          def set_validation_geometry(row)
            return clear_validation_geometry unless row.is_a?(Hash)

            validation_overlay_service.show(@indoor_model.model || @model, row)
          end

          def clear_validation_geometry
            validation_overlay_service.clear
          end

          # Only actual geometry/runtime changes invalidate model-specific overlap
          # evidence. Row switching and deselection use clear_validation_geometry.
          def invalidate_validation_geometry_cache(cell_ids: nil)
            validation_overlay_service.invalidate_geometry_cache(cell_ids: cell_ids)
          end

          def end_validation_session
            validation_overlay_service.end_session
          end

          def validation_overlay_service
            @validation_overlay_service ||= ValidationOverlayService.new(
              indoor_model: @indoor_model,
              overlay_factory: @validation_overlay_factory,
              resolver_factory: @validation_geometry_resolver_factory
            )
          end

          def invalidate_transition_points
            @space_overlay&.invalidate_transition_points
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay transition cache invalidation failed: #{e.class}: #{e.message}"
          end

          def invalidate_primal_render_transform
            @space_overlay&.invalidate_primal_render_transform
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay Primal transform invalidation failed: #{e.class}: #{e.message}"
          end

          def invalidate_transitions(transitions)
            @space_overlay&.invalidate_transitions(transitions)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay Transition invalidation failed: #{e.class}: #{e.message}"
          end

          def remove_transitions(transitions)
            @space_overlay&.remove_transitions(transitions)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay Transition removal failed: #{e.class}: #{e.message}"
          end

          def invalidate_transition_visibility
            @space_overlay&.invalidate_transition_visibility
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay visibility invalidation failed: #{e.class}: #{e.message}"
          end

          def invalidate_transition_selection
            @space_overlay&.invalidate_transition_selection
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay selection invalidation failed: #{e.class}: #{e.message}"
          end

          def clear_transition_cache
            @space_overlay&.clear_transition_cache
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay Transition cache reset failed: #{e.class}: #{e.message}"
          end

          def finish_transition_transform_preview(source: :commit)
            return false unless @space_overlay&.respond_to?(:finish_transition_transform_preview)

            @space_overlay.finish_transition_transform_preview(source: source)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay transition transform finish failed: #{e.class}: #{e.message}"
            false
          end

          def begin_transition_topology_sync(cell_ids)
            return false unless @space_overlay&.respond_to?(:begin_transition_topology_sync)

            @space_overlay.begin_transition_topology_sync(cell_ids)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay transition topology begin failed: #{e.class}: #{e.message}"
            false
          end

          def complete_transition_topology_sync(cell_ids)
            return false unless @space_overlay&.respond_to?(:complete_transition_topology_sync)

            @space_overlay.complete_transition_topology_sync(cell_ids)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Overlay transition topology completion failed: #{e.class}: #{e.message}"
            false
          end

          def invalidate_view(model)
            model.active_view.invalidate if model&.active_view
          end

          private

          def update_enabled_from_model
            update_enabled(
              editing: @indoor_model.respond_to?(:editing?) && @indoor_model.editing?,
              dual_overlay_visible: @indoor_model.respond_to?(:dual_overlay_visible?) && @indoor_model.dual_overlay_visible?
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
              COMPATIBILITY_EDIT_MODE_OVERLAY_ID
            ]
            model.overlays.each do |overlay|
              next unless stale_ids.include?(overlay.overlay_id)
              next if overlay.equal?(@screen_overlay) ||
                      overlay.equal?(@space_overlay)

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
