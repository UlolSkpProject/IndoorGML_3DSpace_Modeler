# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class << self
    attr_accessor :test_defaults
  end

  def self.read_default(section, key, fallback = nil)
    test_defaults.fetch([section, key], fallback)
  end

  def self.write_default(section, key, value)
    test_defaults[[section, key]] = value
  end
end

require_relative '../indoor3d/infrastructure/preferences/user_preferences'
require_relative '../indoor3d/infrastructure/preferences/dual_overlay_preferences'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DualOverlayPreferencesTest < Minitest::Test
        def setup
          Sketchup.test_defaults = {}
        end

        def test_state_radius_scale_defaults_to_one
          assert_equal 1.0, DualOverlayPreferences.state_radius_scale
        end

        def test_state_radius_scale_reads_stored_value
          Sketchup.test_defaults[
            [UserPreferences::SECTION, DualOverlayPreferences::STATE_RADIUS_SCALE_KEY]
          ] = 1.4

          assert_equal 1.4, DualOverlayPreferences.state_radius_scale
        end

        def test_state_radius_scale_clamps_to_min_and_max
          key = [UserPreferences::SECTION, DualOverlayPreferences::STATE_RADIUS_SCALE_KEY]

          Sketchup.test_defaults[key] = 0.1
          assert_equal 0.5, DualOverlayPreferences.state_radius_scale

          Sketchup.test_defaults[key] = 9.0
          assert_equal 2.0, DualOverlayPreferences.state_radius_scale
        end

        def test_state_radius_scale_writer_stores_clamped_value
          DualOverlayPreferences.state_radius_scale = 3.0

          assert_equal(
            2.0,
            Sketchup.test_defaults[[UserPreferences::SECTION, DualOverlayPreferences::STATE_RADIUS_SCALE_KEY]]
          )
        end
      end
    end
  end
end
