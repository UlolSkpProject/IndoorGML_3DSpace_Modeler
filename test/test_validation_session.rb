# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/validity/validation_session'
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
            assert_equal [200], runner_session.terminated_waits
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
            assert_equal [200], runner_session.terminated_waits
          end

          def test_cancel_cleans_workspace_after_process_termination
            model = FakeModel.new('A')
            workspace = FakeWorkspace.new
            session = ValidationSession.new(
              model: model,
              indoor_model: FakeIndoorModel.new(model),
              progress: FakeProgress.new,
              state: {},
              workspace: workspace
            )
            session.assign_val_session(FakeRunnerSession.new(finished: true))

            assert session.cancel(reason: :model_closed)

            assert_equal 1, workspace.cleanup_count
            refute session.cleanup_pending?
          end

          def test_cancel_marks_cleanup_pending_when_process_is_still_running
            model = FakeModel.new('A')
            workspace = FakeWorkspace.new
            state = {}
            session = ValidationSession.new(
              model: model,
              indoor_model: FakeIndoorModel.new(model),
              progress: FakeProgress.new,
              state: state,
              workspace: workspace
            )
            session.assign_val_session(FakeRunnerSession.new(finished: false))

            assert session.cancel(reason: :model_closed)

            assert_equal 0, workspace.cleanup_count
            assert session.cleanup_pending?
            assert state[:workspace_cleanup_pending]
          end

          def test_pending_cleanup_retries_after_process_finishes
            model = FakeModel.new('A')
            workspace = FakeWorkspace.new
            runner_session = FakeRunnerSession.new(finished: false)
            session = ValidationSession.new(
              model: model,
              indoor_model: FakeIndoorModel.new(model),
              progress: FakeProgress.new,
              state: {},
              workspace: workspace
            )
            session.assign_val_session(runner_session)

            assert session.cancel(reason: :model_closed)
            assert_equal 0, workspace.cleanup_count
            assert_equal 1, UI.timers.length

            runner_session.finished = true
            refute UI.timers.last.call

            assert_equal 1, workspace.cleanup_count
            refute session.cleanup_pending?
            assert_equal 1, runner_session.close_count
          end

          def test_complete_cleans_workspace_once
            model = FakeModel.new('A')
            workspace = FakeWorkspace.new
            session = ValidationSession.new(
              model: model,
              indoor_model: FakeIndoorModel.new(model),
              progress: FakeProgress.new,
              state: {},
              workspace: workspace
            )

            assert session.complete
            refute session.complete

            assert_equal 1, workspace.cleanup_count
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
              state: {},
              workspace: FakeWorkspace.new
            )
            dispatcher = CapturingDispatcher.new

            Sketchup.test_active_model = model_b
            dispatcher.send(:perform_check_validity, session)

            assert_same indoor_a, dispatcher.seen_indoor_model
            assert_equal session.workspace.gml_path, dispatcher.seen_output_path
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

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_report('cell_A'), 'temp.gml')
            progress.validation_focus_callback.call(['cell_A'], '701', [], [])

            assert_equal [['cell_A']], indoor_a.begin_focus_calls
            assert_equal [[['cell_A'], '701']], indoor_a.highlight_calls
          end

          def test_report_row_focus_starts_fix_mode_with_all_error_cells_and_highlights_row_only
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_primitive_report, 'temp.gml')
            progress.validation_focus_callback.call(['A'], '203', [], [], 'validation-error-row-0')

            assert_equal [['cell_A', 'cell_B']], indoor_a.begin_focus_calls
            assert_equal %w[A B], indoor_a.begin_focus_row_states.first.flat_map { |row| row[:cells] }
            assert_equal [[['cell_A'], '203']], indoor_a.highlight_calls
            assert_equal 'validation-error-row-0', indoor_a.highlight_details.first[:row_id]
            assert_equal ['A'], indoor_a.highlight_details.first[:row_cells]

            progress.validation_focus_callback.call([], '', [], [])

            assert_equal [['cell_A', 'cell_B']], indoor_a.begin_focus_calls
            assert_equal [[['cell_A'], '203'], [[], '']], indoor_a.highlight_calls
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

          def test_report_fix_includes_primitive_error_parent_cells
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_primitive_report, 'temp.gml')
            progress.fix_callback.call

            assert_equal [['cell_A', 'cell_B']], indoor_a.begin_focus_calls
          end

          def test_report_fix_uses_kept_overlap_recheck_cells_not_broad_raw_refs
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_broad_overlap_recheck, 'temp.gml')
            progress.fix_callback.call

            assert_equal [['cell_A', 'cell_B']], indoor_a.begin_focus_calls
          end

          def test_report_focus_expands_state_and_transition_refs_to_runtime_cells
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            cell_a = FakeCell.new('A')
            cell_b = FakeCell.new('B')
            cell_c = FakeCell.new('C')
            state_a = FakeState.new('A', cell_a)
            state_b = FakeState.new('B', cell_b)
            state_c = FakeState.new('C', cell_c)
            transition_t = FakeTransition.new('T', state_b, state_c)
            indoor_a.states.concat([state_a, state_b, state_c])
            indoor_a.transitions << transition_t
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_state_transition_report, 'temp.gml')
            progress.validation_focus_callback.call([], '901', ['state_A'], [])

            assert_equal [['cell_A', 'cell_B', 'cell_C']], indoor_a.begin_focus_calls
            assert_equal [[['cell_A'], '901']], indoor_a.highlight_calls
          end

          def test_report_focus_expands_prefixed_runtime_ids
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            cell_a = FakeCell.new('cell_A')
            state_a = FakeState.new('state_A', cell_a)
            indoor_a.states << state_a
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_state_transition_report, 'temp.gml')
            progress.validation_focus_callback.call([], '901', ['state_A'], [])

            assert_equal [['cell_cell_A', 'cell_A']], indoor_a.begin_focus_calls
            assert_equal [[['cell_cell_A', 'cell_A'], '901']], indoor_a.highlight_calls
          end

          def test_report_focus_does_not_start_from_solid_cell_callback_without_canonical_report_focus
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_solid_primitive_report, 'temp.gml')
            progress.validation_focus_callback.call(['solid_cell_b67d90rs'], '203', [], [])

            assert_empty indoor_a.begin_focus_calls
            assert_empty indoor_a.highlight_calls
          end

          def test_report_row_focus_does_not_highlight_when_fix_mode_start_fails
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a, begin_focus_result: false)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_report('cell_A'), 'temp.gml')
            progress.validation_focus_callback.call(['cell_A'], '302', [], [])

            assert_equal [['cell_A']], indoor_a.begin_focus_calls
            assert_empty indoor_a.highlight_calls
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
              @timers = []
              class << self
                attr_reader :messages
                attr_reader :timers

                def messagebox(message, *_args)
                  @messages << message
                  nil
                end

                def start_timer(_interval, _repeat, &block)
                  @timers << block
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
            attr_reader :seen_output_path

            def start_temp_file_creation(session, **kwargs)
              @seen_indoor_model = session.indoor_model
              @seen_output_path = kwargs[:output_path]
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
            attr_reader :begin_focus_row_states
            attr_reader :highlight_calls
            attr_reader :highlight_details
            attr_reader :states
            attr_reader :transitions

            def initialize(model, begin_focus_result: true)
              @model = model
              @begin_focus_calls = []
              @begin_focus_row_states = []
              @highlight_calls = []
              @highlight_details = []
              @states = []
              @transitions = []
              @validation_focus_active = false
              @begin_focus_result = begin_focus_result
            end

            def validation_focus_active?
              @validation_focus_active
            end

            def begin_validation_focus_editing(cell_ids, row_states: nil)
              @begin_focus_calls << cell_ids
              @begin_focus_row_states << Array(row_states)
              @validation_focus_active = true if @begin_focus_result
              @begin_focus_result
            end

            def set_validation_focus_highlight(cell_ids, code, row_id: nil, row_cells: nil, states: nil, transitions: nil)
              @highlight_calls << [cell_ids, code]
              @highlight_details << {
                row_id: row_id,
                row_cells: row_cells,
                states: states,
                transitions: transitions
              }
              true
            end
          end

          class FakeWorkspace
            attr_reader :cleanup_count
            attr_reader :gml_path

            def initialize
              @cleanup_count = 0
              @gml_path = 'workspace/input.gml'
            end

            def cleanup
              @cleanup_count += 1
              @cleanup_count == 1
            end
          end

          class FakeRunnerSession
            attr_accessor :finished
            attr_reader :terminated_waits
            attr_reader :close_count

            def initialize(finished: nil)
              @terminated_waits = []
              @finished = finished
              @close_count = 0
            end

            def terminate(wait_ms:)
              @terminated_waits << wait_ms
            end

            def finished?
              @finished == true
            end

            def join_reader; end

            def close
              @close_count += 1
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
                  'features' => [
                    {
                      'id' => cell_id,
                      'errors' => [
                        { 'code' => 302, 'description' => "Invalid #{cell_id}" }
                      ],
                      'primitives' => []
                    }
                  ]
                }
              )
            end

            def self.invalid_with_primitive_report
              new(
                valid: false,
                report: {
                  'features' => [
                    {
                      'id' => 'cell_A',
                      'errors' => [],
                      'primitives' => [
                        {
                          'id' => 'solid_A',
                          'errors' => [
                            { 'code' => 203, 'description' => 'primitive shell is invalid' }
                          ]
                        }
                      ]
                    },
                    {
                      'id' => 'cell_B',
                      'errors' => [
                        { 'code' => 302, 'description' => 'feature is invalid' }
                      ],
                      'primitives' => []
                    }
                  ]
                }
              )
            end

            def self.invalid_with_broad_overlap_recheck
              new(
                valid: false,
                report: {
                  'features' => [
                    {
                      'id' => 'cell_A',
                      'errors' => [
                        {
                          'code' => 701,
                          'description' => 'overlap cell_A cell_B cell_C cell_D'
                        }
                      ],
                      'primitives' => []
                    }
                  ],
                  'indoorgml_modeler_overlap_recheck' => [
                    {
                      'code' => 701,
                      'cells' => %w[cell_A cell_B],
                      'tolerated' => false,
                      'status' => 'kept'
                    }
                  ]
                }
              )
            end

            def self.invalid_with_state_transition_report
              new(
                valid: false,
                report: {
                  'features' => [
                    {
                      'id' => 'state_A',
                      'errors' => [
                        { 'code' => 901, 'description' => 'state issue mentions cell_Z' }
                      ],
                      'primitives' => []
                    },
                    {
                      'id' => 'transition_T',
                      'errors' => [
                        { 'code' => 902, 'description' => 'transition issue mentions cell_Y' }
                      ],
                      'primitives' => []
                    }
                  ]
                }
              )
            end

            def self.invalid_with_solid_primitive_report
              new(
                valid: false,
                report: {
                  'features' => [
                    {
                      'id' => nil,
                      'errors' => [],
                      'primitives' => [
                        {
                          'id' => 'solid_cell_b67d90rs',
                          'errors' => [
                            { 'code' => 203, 'description' => 'primitive shell is invalid' }
                          ]
                        }
                      ]
                    }
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

          FakeCell = Struct.new(:id) do
            def valid?
              true
            end
          end

          FakeState = Struct.new(:id, :duality_cell) do
            def valid?
              true
            end
          end

          FakeTransition = Struct.new(:id, :state1, :state2) do
            def valid?
              true
            end
          end
        end
      end
    end
  end
end
