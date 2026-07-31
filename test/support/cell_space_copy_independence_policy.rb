# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceCopyIndependenceTest
        remove_method :test_failed_copy_independence_rolls_back_runtime_and_clears_copied_attributes if
          instance_methods(false).include?(:test_failed_copy_independence_rolls_back_runtime_and_clears_copied_attributes)

        def test_failed_copy_independence_rolls_back_without_console_output_and_defers_warning
          model = FakeIndoorModel.new(fail_during_sync: true)
          original = model.add_registered_cell('original_cell', 'original_state')
          copy = FakeGroup.new('copy')
          copy.set_attribute('OtherExtension', 'keep', 'yes')
          write_cell_attributes(copy, id: original.id, state_id: original.duality_state.id)

          out, = capture_io { model.primal_entity_added(copy) }

          assert_empty out
          assert_equal [original], model.cell_spaces
          assert_equal [original.duality_state], model.states
          assert_empty model.transitions
          assert_empty original.duality_state.transitions
          assert_empty model.registry.adjacent_pair_keys
          assert_nil model.registry.find_cell_space_for_entity(copy)
          assert_nil copy.get_attribute('IndoorGml', 'feature')
          assert_nil copy.get_attribute('IndoorGml', 'id')
          assert_nil copy.get_attribute('IndoorGml', 'duality_state_id')
          assert_equal 'yes', copy.get_attribute('OtherExtension', 'keep')
          assert_equal 1, model.deferred_messages.length
          assert_match(/CellSpace copy independence failed/, model.deferred_messages.first)

          model.primal_entity_added(copy)

          assert_equal [original], model.cell_spaces
          assert_equal [original.duality_state], model.states
          assert_empty model.transitions
        end
      end
    end
  end
end
