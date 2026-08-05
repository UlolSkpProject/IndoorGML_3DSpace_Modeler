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
require_relative '../indoor3d/ui/export_progress_cancel_visibility'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ExportProgressCancelVisibilityTest < Minitest::Test
          class FakeDialog
            attr_reader :scripts

            def initialize
              @scripts = []
            end

            def visible?
              true
            end

            def execute_script(script)
              @scripts << script
            end
          end

          class FakeProgress
            attr_reader :events

            def initialize
              @events = []
            end

            def cancellable(value)
              @events << value
            end
          end

          class FakeProcessSession
            def terminate(wait_ms: 0)
              wait_ms
            end
          end

          class FakeRunner
            def start(progress: nil, returned_session: nil, **_options)
              returned_session
            end

            private

            def build_result_after_process(_exit_code, progress = nil, **_options)
              progress.events << :recheck
              :built
            end

            def error_result(error)
              error
            end
          end
          FakeRunner.prepend(Val3dityCancellableProgressIntegration)

          def test_dialog_defaults_to_non_cancellable_and_guards_callback
            calls = 0
            dialog = ExportProgressDialog.new
            dialog.on_cancel { calls += 1 }
            callback = dialog.instance_variable_get(:@cancel_callback)

            callback.call
            assert_equal 0, calls

            dialog.cancellable(true)
            callback.call
            assert_equal 1, calls

            dialog.cancellable(false)
            callback.call
            assert_equal 1, calls
          end

          def test_dialog_sends_explicit_cancellable_state_to_html
            fake_dialog = FakeDialog.new
            dialog = ExportProgressDialog.new
            dialog.instance_variable_set(:@dialog, fake_dialog)
            dialog.instance_variable_set(:@dom_ready, true)

            assert_equal true, dialog.cancellable(true)
            assert_equal false, dialog.cancellable(false)
            assert_equal ['setCancellable(true);', 'setCancellable(false);'], fake_dialog.scripts
          end

          def test_terminal_result_disables_cancellation
            fake_dialog = FakeDialog.new
            dialog = ExportProgressDialog.new
            dialog.instance_variable_set(:@dialog, fake_dialog)
            dialog.instance_variable_set(:@dom_ready, true)
            dialog.cancellable(true)

            dialog.result(
              status: :success,
              title: 'Done',
              message: 'Finished',
              actions: [:close]
            )

            assert_equal false, dialog.instance_variable_get(:@cancellable)
            assert_includes fake_dialog.scripts, 'setCancellable(false);'
          end

          def test_val3dity_process_enables_cancel_and_recheck_disables_it_first
            progress = FakeProgress.new
            runner = FakeRunner.new

            session = runner.start(
              progress: progress,
              returned_session: FakeProcessSession.new
            )
            result = runner.send(:build_result_after_process, 0, progress)

            assert_instance_of FakeProcessSession, session
            assert_equal :built, result
            assert_equal [true, false, :recheck], progress.events
          end

          def test_non_process_result_never_enables_cancel
            progress = FakeProgress.new
            runner = FakeRunner.new

            assert_nil runner.start(progress: progress, returned_session: nil)
            assert_equal [false], progress.events
          end

          def test_val3dity_error_disables_cancel
            progress = FakeProgress.new
            runner = FakeRunner.new
            runner.start(
              progress: progress,
              returned_session: FakeProcessSession.new
            )

            error = RuntimeError.new('forced')
            assert_same error, runner.send(:error_result, error)
            assert_equal [true, false], progress.events
          end
        end
      end
    end
  end
end
