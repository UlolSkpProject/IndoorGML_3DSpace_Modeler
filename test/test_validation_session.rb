# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/export/validation_session'
require_relative '../indoor3d/ui/commands/export_commands'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ValidationSessionTest < Minitest::Test
          def setup
            @original_ui = Object.const_get(:UI) if Object.const_defined?(:UI)
            @original_sketchup = Object.const_get(:Sketchup) if Object.const_defined?(:Sketchup)
            Object.send(:remove_const, :UI) if Object.const_defined?(:UI)
            Object.send(:remove_const, :Sketchup) if Object.const_defined?(:Sketchup)
            Object.const_set(:UI, fake_ui)
            Object.const_set(:Sketchup, fake_sketchup)
            ValidationSession.reset!
          end

          def teardown
            ValidationSession.reset!
            Object.send(:remove_const, :UI) if Object.const_defined?(:UI)
            Object.send(:remove_const, :Sketchup) if Object.const_defined?(:Sketchup)
            Object.const_set(:UI, @original_ui) if @original_ui
            Object.const_set(:Sketchup, @original_sketchup) if @original_sketchup
          end

          def test_model_close_cancels_session_and_terminates_process
            model = FakeModel.new('A')
            progress = FakeProgress.new
            state = {}
            runner_session = FakeRunnerSession.new
            cancelled = []
            session = ValidationSession.new(
              model: model,
              indoor_model: FakeIndoorModel.new(model),
              progress: progress,
              state: state,
              on_cancel: proc { |active_session, reason| cancelled << [active_session, reason] }
            )
            session.assign_val_session(runner_session)

            assert_same session, ValidationSession.for_model(model)
            assert ValidationSession.cancel_for_model(model, reason: :model_closed)

            assert_equal :model_closed, session.status
            assert_equal :model_closed, session.cancel_reason
            assert_equal [:model_closed], [state[:cancel_reason]]
            assert_equal [0], runner_session.terminated_waits
            assert_equal 1, progress.close_count
            assert progress.callbacks_cleared
            assert_nil ValidationSession.for_model(model)
            assert_equal [[session, :model_closed]], cancelled
          end

          def test_cancel_is_idempotent
            model = FakeModel.new('A')
            runner_session = FakeRunnerSession.new
            session = ValidationSession.new(
              model: model,
              indoor_model: FakeIndoorModel.new(model),
              progress: FakeProgress.new,
              state: {}
            )
            session.assign_val_session(runner_session)

            assert session.cancel(reason: :model_closed)
            refute session.cancel(reason: :model_closed)
            assert_equal [0], runner_session.terminated_waits
          end

          def test_cancel_except_model_cancels_stale_sessions_only
            model_a = FakeModel.new('A')
            model_b = FakeModel.new('B')
            progress_a = FakeProgress.new
            progress_b = FakeProgress.new
            session_a = ValidationSession.new(
              model: model_a,
              indoor_model: FakeIndoorModel.new(model_a),
              progress: progress_a,
              state: {}
            )
            session_b = ValidationSession.new(
              model: model_b,
              indoor_model: FakeIndoorModel.new(model_b),
              progress: progress_b,
              state: {}
            )

            assert ValidationSession.cancel_except_model(model_b, reason: :model_changed)

            assert_equal :cancelled, session_a.status
            assert_equal :model_changed, session_a.cancel_reason
            assert_equal :running, session_b.status
            assert_equal 1, progress_a.close_count
            assert_equal 0, progress_b.close_count
            assert_nil ValidationSession.for_model(model_a)
            assert_same session_b, ValidationSession.for_model(model_b)
          end

          def test_perform_check_validity_uses_captured_session_indoor_model
            model_a = FakeModel.new('A')
            model_b = FakeModel.new('B')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = ValidationSession.new(
              model: model_a,
              indoor_model: indoor_a,
              progress: progress,
              state: {}
            )
            dispatcher = CapturingDispatcher.new

            Sketchup.test_active_model = model_b
            dispatcher.send(:perform_check_validity, session)

            assert_same indoor_a, dispatcher.seen_indoor_model
          end

          def test_stale_report_focus_action_expires_without_editing_new_model
            model_a = FakeModel.new('A')
            model_b = FakeModel.new('B')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid, 'temp.gml')
            Sketchup.test_active_model = model_b
            progress.validation_focus_callback.call(['cell_A'], '701', [], [])

            assert_empty indoor_a.begin_focus_calls
            assert_empty indoor_a.highlight_calls
            assert_equal [ValidationSession::EXPIRED_MESSAGE], UI.messages
            assert_equal 1, progress.close_count
            assert_equal :cancelled, session.status
          end

          def test_cancelled_session_report_callback_is_no_op
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid, 'temp.gml')
            callback = progress.validation_focus_callback
            session.cancel(reason: :model_closed)
            callback.call(['cell_A'], '701', [], [])

            assert_empty indoor_a.begin_focus_calls
            assert_empty indoor_a.highlight_calls
          end

          def test_report_focus_uses_captured_indoor_model_when_model_is_current
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid, 'temp.gml')
            progress.validation_focus_callback.call(['cell_A'], '701', [], [])

            assert_equal [['cell_A']], indoor_a.begin_focus_calls
            assert_equal [[['cell_A'], '701']], indoor_a.highlight_calls
          end

          def test_report_fix_uses_captured_indoor_model_when_model_is_current
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_report('cell_A'), 'temp.gml')
            progress.fix_callback.call

            assert_equal [['cell_A']], indoor_a.begin_focus_calls
          end

          private

          def result_ready_session(model, indoor_model, progress)
            session = ValidationSession.new(
              model: model,
              indoor_model: indoor_model,
              progress: progress,
              state: {}
            )
            session.result_ready!
            session
          end

          def fake_ui
            Class.new do
              @messages = []
              class << self
                attr_reader :messages

                def messagebox(message, *_args)
                  @messages << message
                  nil
                end
              end
            end
          end

          def fake_sketchup
            Module.new do
              @test_active_model = nil
              class << self
                attr_accessor :test_active_model

                def active_model
                  @test_active_model
                end
              end
            end
          end

          class Dispatcher
            include IndoorCore::ExportCommands
          end

          class CapturingDispatcher < Dispatcher
            attr_reader :seen_indoor_model

            def start_temp_file_creation(session, **_kwargs)
              @seen_indoor_model = session.indoor_model
            end
          end

          class FakeProgress
            attr_reader :close_count
            attr_reader :result_calls
            attr_reader :validation_focus_callback
            attr_reader :fix_callback

            def initialize
              @close_count = 0
              @result_calls = []
              @callbacks_cleared = false
            end

            def on_create_gml(&block)
              @create_gml_callback = block
            end

            def on_open_report(&block)
              @open_report_callback = block
            end

            def on_validation_focus_cells(&block)
              @validation_focus_callback = block
            end

            def on_fix_validation_errors(&block)
              @fix_callback = block
            end

            def result(payload)
              @result_calls << payload
            end

            def close
              @close_count += 1
            end

            def visible?
              @close_count.zero?
            end

            def clear_callbacks
              @callbacks_cleared = true
            end

            def callbacks_cleared
              @callbacks_cleared == true
            end
          end

          class FakeModel
            attr_reader :name

            def initialize(name)
              @name = name
            end
          end

          class FakeIndoorModel
            attr_reader :model
            attr_reader :begin_focus_calls
            attr_reader :highlight_calls
            attr_reader :states
            attr_reader :transitions

            def initialize(model)
              @model = model
              @begin_focus_calls = []
              @highlight_calls = []
              @states = []
              @transitions = []
              @validation_focus_active = false
            end

            def validation_focus_active?
              @validation_focus_active
            end

            def begin_validation_focus_editing(cell_ids)
              @begin_focus_calls << cell_ids
              @validation_focus_active = true
              true
            end

            def set_validation_focus_highlight(cell_ids, code)
              @highlight_calls << [cell_ids, code]
              true
            end
          end

          class FakeRunnerSession
            attr_reader :terminated_waits

            def initialize
              @terminated_waits = []
            end

            def terminate(wait_ms:)
              @terminated_waits << wait_ms
            end
          end

          class FakeResult
            attr_reader :report

            def self.invalid
              new(valid: false, report: {})
            end

            def self.invalid_with_report(cell_id)
              new(
                valid: false,
                report: {
                  'dataset_errors' => [
                    { 'message' => "Invalid #{cell_id}" }
                  ]
                }
              )
            end

            def initialize(valid:, report:)
              @valid = valid
              @report = report
            end

            def valid?
              @valid
            end

            def error?
              false
            end

            def report_html_path
              'report.html'
            end
          end
        end
      end
    end
  end
end
