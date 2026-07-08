# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/infrastructure/scene/editor_session/overlay_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModeScreenOverlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.indoor_mode_screen_overlay'
      end unless const_defined?(:IndoorModeScreenOverlay)

      class DualGraphSpaceOverlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.dual_graph_space_overlay'
      end unless const_defined?(:DualGraphSpaceOverlay)

      class EditorSessionOverlayControllerTest < Minitest::Test
        def test_ensure_registered_adds_screen_and_space_overlays_and_removes_stale_instances
          stale_screen = fake_overlay(IndoorModeScreenOverlay::OVERLAY_ID)
          stale_space = fake_overlay(DualGraphSpaceOverlay::OVERLAY_ID)
          stale_legacy = fake_overlay(EditorSession::OverlayController::LEGACY_EDIT_MODE_OVERLAY_ID)
          unrelated = fake_overlay('other.overlay')
          overlays = fake_overlays([stale_screen, stale_space, stale_legacy, unrelated])
          model = fake_model(overlays: overlays)
          screen_overlay = fake_overlay(IndoorModeScreenOverlay::OVERLAY_ID)
          space_overlay = fake_overlay(DualGraphSpaceOverlay::OVERLAY_ID)
          controller = EditorSession::OverlayController.new(
            indoor_model: fake_indoor_model(editing: true, dual_overlay_visible: true),
            screen_overlay_factory: proc { screen_overlay },
            space_overlay_factory: proc { space_overlay }
          )

          controller.ensure_registered(model)

          assert_includes overlays.items, screen_overlay
          assert_includes overlays.items, space_overlay
          refute_includes overlays.items, stale_screen
          refute_includes overlays.items, stale_space
          refute_includes overlays.items, stale_legacy
          assert_includes overlays.items, unrelated
          assert_equal true, screen_overlay.enabled
          assert_equal true, space_overlay.enabled
        end

        def test_ensure_registered_same_model_does_not_add_duplicates
          overlays = fake_overlays
          model = fake_model(overlays: overlays)
          screen_overlay = fake_overlay(IndoorModeScreenOverlay::OVERLAY_ID)
          space_overlay = fake_overlay(DualGraphSpaceOverlay::OVERLAY_ID)
          controller = EditorSession::OverlayController.new(
            indoor_model: fake_indoor_model(editing: false, dual_overlay_visible: false),
            screen_overlay_factory: proc { screen_overlay },
            space_overlay_factory: proc { space_overlay }
          )

          controller.ensure_registered(model)
          controller.ensure_registered(model)

          assert_equal 1, overlays.items.count { |item| item.equal?(screen_overlay) }
          assert_equal 1, overlays.items.count { |item| item.equal?(space_overlay) }
        end

        def test_update_enabled_applies_screen_and_space_conditions_independently
          screen_overlay = fake_overlay(IndoorModeScreenOverlay::OVERLAY_ID)
          space_overlay = fake_overlay(DualGraphSpaceOverlay::OVERLAY_ID)
          controller = EditorSession::OverlayController.new(
            indoor_model: fake_indoor_model(editing: false, dual_overlay_visible: false),
            screen_overlay_factory: proc { screen_overlay },
            space_overlay_factory: proc { space_overlay }
          )
          controller.ensure_registered(fake_model)

          controller.update_enabled(editing: false, dual_overlay_visible: false, progress_active: false)
          assert_equal false, screen_overlay.enabled
          assert_equal false, space_overlay.enabled

          controller.update_enabled(editing: true, dual_overlay_visible: false, progress_active: false)
          assert_equal true, screen_overlay.enabled
          assert_equal false, space_overlay.enabled

          controller.update_enabled(editing: false, dual_overlay_visible: true, progress_active: false)
          assert_equal false, screen_overlay.enabled
          assert_equal true, space_overlay.enabled

          controller.update_enabled(editing: false, dual_overlay_visible: false, progress_active: true)
          assert_equal false, screen_overlay.enabled
          assert_equal false, space_overlay.enabled
        end

        def test_invalidate_transition_points_only_targets_space_overlay
          screen_overlay = fake_overlay(IndoorModeScreenOverlay::OVERLAY_ID)
          space_overlay = fake_overlay(DualGraphSpaceOverlay::OVERLAY_ID)
          view = fake_view
          controller = EditorSession::OverlayController.new(
            indoor_model: fake_indoor_model(editing: true, dual_overlay_visible: true),
            screen_overlay_factory: proc { screen_overlay },
            space_overlay_factory: proc { space_overlay }
          )
          controller.ensure_registered(fake_model(active_view: view))

          controller.invalidate_transition_points
          controller.invalidate_view(fake_model(active_view: view))

          assert_equal false, screen_overlay.transition_points_invalidated
          assert_equal true, space_overlay.transition_points_invalidated
          assert_equal true, view.invalidated
        end

        private

        def fake_overlay(overlay_id)
          Class.new do
            attr_accessor :enabled
            attr_reader :transition_points_invalidated

            def initialize(overlay_id)
              @overlay_id = overlay_id
              @enabled = false
              @transition_points_invalidated = false
            end

            def valid?
              true
            end

            def overlay_id
              @overlay_id
            end

            def invalidate_transition_points
              @transition_points_invalidated = true
            end
          end.new(overlay_id)
        end

        def fake_indoor_model(editing:, dual_overlay_visible:)
          Struct.new(:editing_value, :dual_overlay_value) do
            def editing?
              editing_value
            end

            def dual_overlay_visible?
              dual_overlay_value
            end

            def progress_active?
              true
            end
          end.new(editing, dual_overlay_visible)
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
