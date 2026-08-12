# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/precision_validation/crash_state'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationCrashStateTest < Minitest::Test
        class Group
          def initialize
            @attributes = {}
          end

          def valid? = true

          def get_attribute(dictionary, key, default = nil)
            @attributes.fetch([dictionary, key], default)
          end

          def set_attribute(dictionary, key, value)
            @attributes[[dictionary, key]] = value
          end

          def delete_attribute(dictionary, key)
            @attributes.delete([dictionary, key])
          end
        end

        CellSpace = Struct.new(:sketchup_group)

        def test_passed_crash_check_is_persisted
          group = Group.new

          assert PrecisionValidation::CrashState.set(group, crashed: false)

          assert PrecisionValidation::CrashState.checked?(group)
          refute PrecisionValidation::CrashState.crashed?(group)
          assert_equal 'passed', PrecisionValidation::CrashState.status(group)
          assert_equal 'passed', group.get_attribute('IndoorGml', 'precision_crash_status')
          assert_equal true, group.get_attribute('IndoorGml', 'precision_crash_checked')
          assert_equal false, group.get_attribute('IndoorGml', 'precision_crash_detected')
        end

        def test_crashed_cell_space_is_persisted_through_wrapper
          group = Group.new
          cell_space = CellSpace.new(group)

          assert PrecisionValidation::CrashState.set(cell_space, crashed: true)

          assert PrecisionValidation::CrashState.checked?(cell_space)
          assert PrecisionValidation::CrashState.crashed?(cell_space)
          assert_equal 'crashed', PrecisionValidation::CrashState.status(cell_space)
        end

        def test_clear_marks_cached_crash_result_unknown_after_change
          group = Group.new
          PrecisionValidation::CrashState.set(group, crashed: true)

          assert PrecisionValidation::CrashState.clear(group)

          refute PrecisionValidation::CrashState.checked?(group)
          refute PrecisionValidation::CrashState.crashed?(group)
          assert_equal 'unknown', PrecisionValidation::CrashState.status(group)
          assert_equal 'unknown', group.get_attribute('IndoorGml', 'precision_crash_status')
          assert_equal false, group.get_attribute('IndoorGml', 'precision_crash_checked')
          assert_equal false, group.get_attribute('IndoorGml', 'precision_crash_detected')
        end

        def test_new_cell_space_can_be_explicitly_marked_unknown
          group = Group.new

          assert PrecisionValidation::CrashState.clear(group)

          assert_equal 'unknown', group.get_attribute('IndoorGml', 'precision_crash_status')
          refute PrecisionValidation::CrashState.checked?(group)
        end

        def test_legacy_boolean_state_remains_readable
          group = Group.new
          group.set_attribute('IndoorGml', 'precision_crash_checked', true)
          group.set_attribute('IndoorGml', 'precision_crash_detected', true)

          assert_equal 'crashed', PrecisionValidation::CrashState.status(group)
          assert PrecisionValidation::CrashState.checked?(group)
          assert PrecisionValidation::CrashState.crashed?(group)
        end
      end
    end
  end
end
