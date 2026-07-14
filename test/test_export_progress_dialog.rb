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
        end
      end
    end
  end
end
