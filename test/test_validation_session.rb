# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/validity/validation_session'
require_relative '../indoor3d/validity/val3dity_report_renderer'
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
            assert_equal 1, UI.stopped_timers.length
          end

          def test_repeated_pending_cleanup_stops_every_owned_timer
            100.times do |index|
              model = FakeModel.new("model-#{index}")
              runner_session = FakeRunnerSession.new(finished: false)
              session = ValidationSession.new(
                model: model,
                indoor_model: FakeIndoorModel.new(model),
                progress: FakeProgress.new,
                state: {},
                workspace: FakeWorkspace.new
              )
              session.assign_val_session(runner_session)
              session.cancel(reason: :model_closed)
              runner_session.finished = true
              UI.timers.last.call
            end

            assert_equal 100, UI.stopped_timers.length
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

          def test_export_gml_finishes_editing_before_export
            model = FakeModel.new('A')
            indoor = FakeIndoorModel.new(model)
            indoor.editing = true
            dispatcher = Dispatcher.new
            UI.savepanel_path = File.join(Dir.pwd, 'tmp', 'general_export')

            with_replaced_constant(IndoorCore, :IndoorModel, fake_indoor_model_class(indoor)) do
              with_replaced_constant(IndoorGmlConverter, :GmlExporter, FakeGmlExporter) do
                dispatcher.export_gml
              end
            end

            assert_equal 1, indoor.finish_editing_count
            assert_same indoor, FakeGmlExporter.last_indoor_model
            assert_equal false, FakeGmlExporter.last_options[:refresh_runtime_data]
            assert_equal "#{UI.savepanel_path}.gml", FakeGmlExporter.last_output_path
          ensure
            FakeGmlExporter.reset
          end

          def test_report_export_regenerates_gml_from_current_runtime_model
            model = FakeModel.new('A')
            indoor = FakeIndoorModel.new(model)
            indoor.editing = true
            progress = FakeProgress.new
            session = result_ready_session(model, indoor, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model
            UI.savepanel_path = File.join(Dir.pwd, 'tmp', 'report_runtime_export')

            with_replaced_constant(IndoorGmlConverter, :GmlExporter, FakeGmlExporter) do
              dispatcher.send(:handle_validation_result, session, FakeResult.invalid, 'obsolete-temp.gml')
              progress.create_gml_callback.call
            end

            assert_equal 1, indoor.finish_editing_count
            assert_same indoor, FakeGmlExporter.last_indoor_model
            assert_equal false, FakeGmlExporter.last_options[:refresh_runtime_data]
            assert_equal "#{UI.savepanel_path}.gml", FakeGmlExporter.last_output_path
            assert_equal "GML exported:\n#{UI.savepanel_path}.gml", progress.result_message
          ensure
            FakeGmlExporter.reset
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

          def test_report_row_focus_uses_updated_memory_refs_instead_of_stale_dom_refs
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_primitive_report, 'temp.gml')
            progress.validation_focus_callback.call(['A'], '203', [], [], 'validation-error-row-0')
            indoor_a.replace_validation_focus_row_cells('validation-error-row-0', %w[A C])

            progress.validation_focus_callback.call(['A'], '203', [], [], 'validation-error-row-0')

            assert_equal %w[cell_A cell_C], indoor_a.highlight_calls.last.first
            assert_equal %w[A C], indoor_a.highlight_details.last[:row_cells]
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

          def test_grouped_report_row_ids_and_refs_match_renderer_and_fix_mode_states
            report = {
              'validity' => false,
              'features_overview' => [{ 'total' => 1, 'valid' => 0 }],
              'primitives_overview' => [{ 'total' => 1, 'valid' => 0 }],
              'parameters' => {},
              'features' => [
                {
                  'id' => 'cell_A',
                  'errors' => [
                    {
                      'id' => 'cell_A and cell_B state_S',
                      'code' => 203,
                      'description' => 'INVALID_SHELL'
                    }
                  ],
                  'primitives' => [
                    {
                      'id' => 'solid_cell_B and cell_A transition_T',
                      'errors' => [{ 'code' => 203, 'description' => 'INVALID_SHELL' }]
                    }
                  ]
                }
              ]
            }
            indoor_model = FakeIndoorModel.new(FakeModel.new('A'))
            states = Dispatcher.new.send(:validation_report_focus_row_states, report, indoor_model)
            html = Val3dityReportRenderer.new.render(report)
            rendered_ids = html.scan(/<details class="recheck-row validation-error-row[^"]*" data-row-id="([^"]+)"/).flatten

            assert_equal states.map { |row| row[:id] }, rendered_ids
            assert_equal 1, states.length
            assert_equal %w[A B], states.first[:cells]
            assert_equal ['state_S'], states.first[:states]
            assert_equal ['transition_T'], states.first[:transitions]
            assert_includes html, 'data-cells="A,B"'
            assert_includes html, 'data-states="state_S"'
            assert_includes html, 'data-transitions="transition_T"'
          end

          def test_focus_row_states_include_export_polygon_face_references
            report = {
              'features' => [
                {
                  'id' => 'IF_001',
                  'errors' => [],
                  'primitives' => [
                    {
                      'id' => 'solid_cell_A',
                      'errors' => [
                        {
                          'id' => 'polygon_11_cell_A',
                          'code' => 203,
                          'description' => 'NON_PLANAR_POLYGON_DISTANCE_PLANE'
                        },
                        {
                          'id' => 'polygon_28_cell_A',
                          'code' => 203,
                          'description' => 'NON_PLANAR_POLYGON_DISTANCE_PLANE'
                        }
                      ]
                    }
                  ]
                }
              ]
            }
            indoor_model = FakeIndoorModel.new(FakeModel.new('A'))

            states = Dispatcher.new.send(
              :validation_report_focus_row_states,
              report,
              indoor_model
            )

            assert_equal 1, states.length
            assert_equal [
              { cell_id: 'A', face_index: 11 },
              { cell_id: 'A', face_index: 28 }
            ], states.first.dig(:geometry_refs, :faces)
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

          def test_report_focus_starts_from_solid_cell_primitive_ref
            model_a = FakeModel.new('A')
            indoor_a = FakeIndoorModel.new(model_a)
            progress = FakeProgress.new
            session = result_ready_session(model_a, indoor_a, progress)
            dispatcher = Dispatcher.new
            Sketchup.test_active_model = model_a

            dispatcher.send(:handle_validation_result, session, FakeResult.invalid_with_solid_primitive_report, 'temp.gml')
            progress.validation_focus_callback.call(['solid_cell_b67d90rs'], '203', [], [])

            assert_equal [['cell_b67d90rs']], indoor_a.begin_focus_calls
            assert_equal [[['cell_b67d90rs'], '203']], indoor_a.highlight_calls
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
              @stopped_timers = []
              @savepanel_path = nil
              class << self
                attr_reader :messages
                attr_reader :timers
                attr_reader :stopped_timers
                attr_accessor :savepanel_path

                def messagebox(message, *_args)
                  @messages << message
                  nil
                end

                def savepanel(_title, _directory, _filter)
                  @savepanel_path
                end

                def start_timer(_interval, _repeat, &block)
                  @timers << block
                end

                def stop_timer(timer_id)
                  @stopped_timers << timer_id
                  true
                end
              end
            end
          end

          def fake_indoor_model_class(indoor_model)
            Class.new do
              define_singleton_method(:current) { indoor_model }
            end
          end

          def with_replaced_constant(namespace, name, value)
            existed = namespace.const_defined?(name, false)
            original = namespace.const_get(name, false) if existed
            namespace.send(:remove_const, name) if existed
            namespace.const_set(name, value)
            yield
          ensure
            namespace.send(:remove_const, name) if namespace.const_defined?(name, false)
            namespace.const_set(name, original) if existed
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
            attr_reader :create_gml_callback
            attr_reader :result_message

            def initialize
              @close_count = 0
              @result_calls = []
              @callbacks_cleared = false
            end

            def on_create_gml(&block)
              @create_gml_callback = block
            end

            def set_result_message(message)
              @result_message = message
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
            attr_accessor :editing
            attr_reader :model
            attr_reader :begin_focus_calls
            attr_reader :begin_focus_row_states
            attr_reader :highlight_calls
            attr_reader :highlight_details
            attr_reader :states
            attr_reader :transitions
            attr_reader :finish_editing_count

            def initialize(model, begin_focus_result: true)
              @model = model
              @editing = false
              @finish_editing_count = 0
              @begin_focus_calls = []
              @begin_focus_row_states = []
              @highlight_calls = []
              @highlight_details = []
              @states = []
              @transitions = []
              @focus_rows = {}
              @validation_focus_active = false
              @begin_focus_result = begin_focus_result
            end

            def editing?
              @editing == true
            end

            def finish_editing
              @finish_editing_count += 1
              @editing = false
              true
            end

            def validation_focus_active?
              @validation_focus_active
            end

            def begin_validation_focus_editing(cell_ids, row_states: nil)
              @begin_focus_calls << cell_ids
              @begin_focus_row_states << Array(row_states)
              @focus_rows = Array(row_states).each_with_object({}) do |row, memo|
                memo[row[:id].to_s] = row.dup
              end
              @validation_focus_active = true if @begin_focus_result
              @begin_focus_result
            end

            def validation_focus_row(row_id)
              row = @focus_rows[row_id.to_s]
              return nil unless row

              row.merge(
                cells: Array(row[:cells]).dup,
                states: Array(row[:states]).dup,
                transitions: Array(row[:transitions]).dup,
                focus_ids: Array(row[:focus_ids]).dup
              )
            end

            def replace_validation_focus_row_cells(row_id, cells)
              row = @focus_rows.fetch(row_id.to_s)
              row[:cells] = Array(cells).dup
              row[:focus_ids] = Array(cells).map { |cell_id| "cell_#{cell_id}" }
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

          class FakeGmlExporter
            class << self
              attr_reader :last_indoor_model
              attr_reader :last_options
              attr_reader :last_output_path

              def new(indoor_model, **options)
                @last_indoor_model = indoor_model
                @last_options = options
                allocate
              end

              def reset
                @last_indoor_model = nil
                @last_options = nil
                @last_output_path = nil
              end

              def record_output_path(path)
                @last_output_path = path
              end
            end

            def export(output_path:)
              self.class.record_output_path(output_path)
              output_path
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
