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

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class UserPreferencesTest < Minitest::Test
        def setup
          Sketchup.test_defaults = {}
        end

        def test_read_float_returns_stored_float
          Sketchup.test_defaults[[UserPreferences::SECTION, 'radius']] = '1.25'

          assert_equal 1.25, UserPreferences.read_float('radius', fallback: 1.0)
        end

        def test_read_float_uses_fallback_for_invalid_value
          Sketchup.test_defaults[[UserPreferences::SECTION, 'radius']] = 'bad'

          assert_equal 1.0, UserPreferences.read_float('radius', fallback: 1.0)
        end

        def test_read_float_clamps_min_and_max
          Sketchup.test_defaults[[UserPreferences::SECTION, 'small']] = 0.1
          Sketchup.test_defaults[[UserPreferences::SECTION, 'large']] = 10.0

          assert_equal 0.5, UserPreferences.read_float('small', fallback: 1.0, min: 0.5, max: 2.0)
          assert_equal 2.0, UserPreferences.read_float('large', fallback: 1.0, min: 0.5, max: 2.0)
        end

        def test_write_float_clamps_and_stores_value
          value = UserPreferences.write_float('radius', 9.0, fallback: 1.0, min: 0.5, max: 2.0)

          assert_equal 2.0, value
          assert_equal 2.0, Sketchup.test_defaults[[UserPreferences::SECTION, 'radius']]
        end
      end
    end
  end
end
