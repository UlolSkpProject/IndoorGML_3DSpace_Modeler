# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/precision_validation/lvn_state'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationLvnStateTest < Minitest::Test
        class Group
          def initialize
            @attributes = {}
          end

          def valid?
            true
          end

          def get_attribute(dictionary, key, default = nil)
            @attributes.fetch([dictionary, key], default)
          end

          def set_attribute(dictionary, key, value)
            @attributes[[dictionary, key]] = value
          end
        end

        CellSpace = Struct.new(:sketchup_group)

        def setup
          @group = Group.new
        end

        def test_false_is_written_explicitly_for_new_cell_space
          assert PrecisionValidation::LvnState.set_failed(@group, false)
          assert_equal false,
                       @group.get_attribute('IndoorGml', 'lvn_failed')
          refute PrecisionValidation::LvnState.failed?(@group)
        end

        def test_true_marks_failure
          assert PrecisionValidation::LvnState.set_failed(@group, true)
          assert_equal true,
                       @group.get_attribute('IndoorGml', 'lvn_failed')
          assert PrecisionValidation::LvnState.failed?(@group)
        end

        def test_same_value_is_not_written_again
          assert PrecisionValidation::LvnState.set_failed(@group, true)
          refute PrecisionValidation::LvnState.set_failed(@group, true)
          assert PrecisionValidation::LvnState.failed?(@group)
        end

        def test_success_clears_failure_flag
          PrecisionValidation::LvnState.set_failed(@group, true)

          assert PrecisionValidation::LvnState.set_failed(@group, false)
          refute PrecisionValidation::LvnState.failed?(@group)
        end

        def test_cell_space_wrapper_uses_sketchup_group
          cell_space = CellSpace.new(@group)

          assert PrecisionValidation::LvnState.set_failed(cell_space, true)
          assert PrecisionValidation::LvnState.failed?(cell_space)
        end

        def test_signature_api_and_constants_are_removed
          refute_respond_to PrecisionValidation::LvnState, :geometry_signature
          refute_respond_to PrecisionValidation::LvnState, :failure_signature
          refute_respond_to PrecisionValidation::LvnState,
                            :geometry_changed_since_failure?
          refute_respond_to PrecisionValidation::LvnState,
                            :failed_and_unchanged?
          refute PrecisionValidation::LvnState.const_defined?(
            :COMPATIBILITY_FAILED_SIGNATURE_KEY,
            false
          )
          refute PrecisionValidation::LvnState.const_defined?(
            :SIGNATURE_VERSION,
            false
          )
        end
      end
    end
  end
end
