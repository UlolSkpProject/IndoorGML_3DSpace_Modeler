# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module HtmlDialogMetrics
        WINDOW_CHROME_HEIGHT = 44 unless const_defined?(:WINDOW_CHROME_HEIGHT, false)
      end

      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/validity/val3dity_runner'
require_relative '../indoor3d/ui/export_progress_dialog'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ExportProgressDialogTest < Minitest::Test
          def setup
            Val3dityRunner.instance_variable_set(:@shutting_down, false)
          end

          def test_window_close_is_session_local_and_does_not_mark_extension_shutdown
            close_requests = 0
            dialog = ExportProgressDialog.new
            dialog.on_request_close do
              close_requests += 1
              :close
            end

            dialog.send(:handle_window_closed)

            assert_equal 1, close_requests
            refute Val3dityRunner.shutting_down?
          end

          def test_new_dialog_can_close_normally_after_previous_dialog_closed
            first = ExportProgressDialog.new
            first.on_request_close { :close }
            first.send(:handle_window_closed)

            second_close_requests = 0
            second = ExportProgressDialog.new
            second.on_request_close do
              second_close_requests += 1
              :close
            end
            second.send(:handle_window_closed)

            assert_equal 1, second_close_requests
            refute Val3dityRunner.shutting_down?
          end

          def test_report_dom_ready_flushes_queued_row_updates
            executed_scripts = []
            fake_dialog = Struct.new(:executed_scripts) do
              def visible?
                true
              end

              def execute_script(script)
                executed_scripts << script
              end
            end.new(executed_scripts)
            dialog = ExportProgressDialog.new
            dialog.instance_variable_set(:@dialog, fake_dialog)

            dialog.update_validation_focus_row(
              row_id: 'validation-error-row-0',
              cells: %w[A B],
              label: 'cell_A and cell_B'
            )
            assert_empty executed_scripts

            dialog.send(:handle_report_dom_ready)

            assert_equal true, dialog.instance_variable_get(:@dom_ready)
            assert_equal 1, executed_scripts.length
            assert_includes executed_scripts.first, 'updateValidationFocusRow'
            assert_includes executed_scripts.first, '"cells":["A","B"]'
            assert_empty dialog.instance_variable_get(:@pending_scripts)
          end

          def test_clear_validation_focus_selection_executes_report_function
            executed_scripts = []
            fake_dialog = Struct.new(:executed_scripts) do
              def visible?
                true
              end

              def execute_script(script)
                executed_scripts << script
              end
            end.new(executed_scripts)
            dialog = ExportProgressDialog.new
            dialog.instance_variable_set(:@dialog, fake_dialog)
            dialog.instance_variable_set(:@dom_ready, true)

            dialog.clear_validation_focus_selection

            assert_equal 1, executed_scripts.length
            assert_includes executed_scripts.first, 'clearValidationFocusSelection();'
          end
        end
      end
    end
  end
end
