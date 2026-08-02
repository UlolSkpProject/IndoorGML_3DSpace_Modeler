# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionDirectHistoryApiTest < Minitest::Test
        def test_direct_history_patch_uses_supported_undo_and_redo_methods
          source = read_dev_file('cell_space_conversion_apply_direct_history_patch.rb')

          assert_includes source, 'Sketchup.undo'
          assert_includes source, 'Sketchup.redo'
          refute_includes source, "Sketchup.send_action('editUndo:')"
          refute_includes source, "Sketchup.send_action('editRedo:')"
        end

        def test_runner_definition_loads_direct_history_patch
          source = read_dev_file('cell_space_conversion_progress_apply_runner.rb')

          assert_includes source, "require_relative 'cell_space_conversion_apply_direct_history_patch'"
          assert_includes source, 'module CellSpaceConversionProgressApplyRunner'
        end

        def test_auto_run_file_loads_runner_definition_then_runs_it
          source = read_dev_file('run_cell_space_conversion_progress_apply.rb')

          assert_includes source, "require_relative 'cell_space_conversion_progress_apply_runner'"
          assert_includes source, 'CellSpaceConversionProgressApplyRunner.run!'
          refute_includes source, 'module CellSpaceConversionProgressApplyRunner'
        end

        private

        def read_dev_file(name)
          File.read(
            File.expand_path(
              "../dev/threaded_progress_infrastructure/#{name}",
              __dir__
            )
          )
        end
      end
    end
  end
end
