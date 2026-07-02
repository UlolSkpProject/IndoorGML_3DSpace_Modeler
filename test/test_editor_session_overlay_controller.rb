# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/infrastructure/scene/editor_session/overlay_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditModeOverlay
        OVERLAY_ID = 'ulol.indoor3d.edit_mode'
      end unless const_defined?(:EditModeOverlay)

      class EditorSessionOverlayControllerTest < Minitest::Test
        def test_ensure_registered_adds_overlay_and_removes_stale_instances
          stale = fake_overlay
          overlays = fake_overlays([stale])
          model = fake_model(overlays: overlays)
          overlay = fake_overlay
          controller = EditorSession::OverlayController.new(
            indoor_model: Object.new,
            overlay_factory: proc { overlay }
          )

          controller.ensure_registered(model)

          assert_includes overlays.items, overlay
          refute_includes overlays.items, stale
          assert_equal true, overlay.enabled
        end

        def test_ensure_registered_same_model_does_not_add_duplicate
          overlays = fake_overlays
          model = fake_model(overlays: overlays)
          overlay = fake_overlay
          controller = EditorSession::OverlayController.new(
            indoor_model: Object.new,
            overlay_factory: proc { overlay }
          )

          controller.ensure_registered(model)
          controller.ensure_registered(model)

          assert_equal 1, overlays.items.count { |item| item.equal?(overlay) }
        end

        def test_update_enabled_uses_editing_dual_or_progress_state
          overlay = fake_overlay
          controller = EditorSession::OverlayController.new(
            indoor_model: Object.new,
            overlay_factory: proc { overlay }
          )
          controller.ensure_registered(fake_model)

          controller.update_enabled(editing: false, dual_overlay_visible: false, progress_active: false)
          assert_equal false, overlay.enabled

          controller.update_enabled(editing: true, dual_overlay_visible: false, progress_active: false)
          assert_equal true, overlay.enabled

          controller.update_enabled(editing: false, dual_overlay_visible: true, progress_active: false)
          assert_equal true, overlay.enabled

          controller.update_enabled(editing: false, dual_overlay_visible: false, progress_active: true)
          assert_equal true, overlay.enabled
        end

        def test_invalidate_transition_points_and_view
          overlay = fake_overlay
          view = fake_view
          controller = EditorSession::OverlayController.new(
            indoor_model: Object.new,
            overlay_factory: proc { overlay }
          )
          controller.ensure_registered(fake_model(active_view: view))

          controller.invalidate_transition_points
          controller.invalidate_view(fake_model(active_view: view))

          assert_equal true, overlay.transition_points_invalidated
          assert_equal true, view.invalidated
        end

        private

        def fake_overlay
          Class.new do
            attr_accessor :enabled
            attr_reader :transition_points_invalidated

            def initialize
              @enabled = false
              @transition_points_invalidated = false
            end

            def valid?
              true
            end

            def overlay_id
              EditModeOverlay::OVERLAY_ID
            end

            def invalidate_transition_points
              @transition_points_invalidated = true
            end
          end.new
        end

        def fake_overlays(items = [])
          Class.new do
            attr_reader :items

            def initialize(items)
              @items = items.dup
            end

            def add(overlay)
              @items << overlay
            end

            def remove(overlay)
              @items.delete(overlay)
            end

            def each(&block)
              @items.each(&block)
            end
          end.new(items)
        end

        def fake_view
          Class.new do
            attr_reader :invalidated

            def invalidate
              @invalidated = true
            end
          end.new
        end

        def fake_model(overlays: fake_overlays, active_view: fake_view)
          Struct.new(:overlays, :active_view).new(overlays, active_view)
        end
      end
    end
  end
end
