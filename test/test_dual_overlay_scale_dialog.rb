# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class << self
    attr_accessor :test_defaults, :test_active_model
  end

  def self.read_default(section, key, fallback = nil)
    test_defaults.fetch([section, key], fallback)
  end

  def self.write_default(section, key, value)
    test_defaults[[section, key]] = value
  end

  def self.active_model
    test_active_model
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/infrastructure/preferences/user_preferences'
require_relative '../indoor3d/infrastructure/preferences/dual_overlay_preferences'
require_relative '../indoor3d/ui/html_dialog_metrics'
require_relative '../indoor3d/ui/dual_overlay_scale_dialog'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DualOverlayScaleDialogTest < Minitest::Test
        def setup
          Sketchup.test_defaults = {}
          Sketchup.test_active_model = fake_model
        end

        def teardown
          Sketchup.test_active_model = nil
        end

        def test_apply_state_radius_scale_stores_preference_and_invalidates_view
          dialog = DualOverlayScaleDialog.new

          assert_equal 1.24, dialog.apply_state_radius_scale('1.236')

          assert_equal 1.24, stored_scale
          assert_equal true, Sketchup.test_active_model.active_view.invalidated
        end

        def test_apply_state_radius_scale_clamps_to_preference_range
          dialog = DualOverlayScaleDialog.new

          assert_equal 3.0, dialog.apply_state_radius_scale('9.0')

          assert_equal 3.0, stored_scale
        end

        def test_reset_state_radius_scale_stores_default_and_invalidates_view
          DualOverlayPreferences.state_radius_scale = 2.0
          dialog = DualOverlayScaleDialog.new

          assert_equal 1.0, dialog.reset_state_radius_scale

          assert_equal 1.0, stored_scale
          assert_equal true, Sketchup.test_active_model.active_view.invalidated
        end

        private

        def stored_scale
          Sketchup.test_defaults[[UserPreferences::SECTION, DualOverlayPreferences::STATE_RADIUS_SCALE_KEY]]
        end

        def fake_model
          Struct.new(:active_view).new(fake_view)
        end

        def fake_view
          Class.new do
            attr_reader :invalidated

            def invalidate
              @invalidated = true
            end
          end.new
        end
      end
    end
  end
end
