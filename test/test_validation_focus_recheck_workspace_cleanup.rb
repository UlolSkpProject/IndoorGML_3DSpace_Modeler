# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)

      module IndoorGmlConverter
        class Val3dityRunner
          TERMINATE_WAIT_MS = 200 unless const_defined?(:TERMINATE_WAIT_MS)
        end unless const_defined?(:Val3dityRunner)
      end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/editor_control'
require_relative '../indoor3d/ui/commands/export_commands'
require_relative '../indoor3d/ui/commands/cell_space_commands'
require_relative '../indoor3d/ui/commands/display_commands'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ValidationFocusRecheckWorkspaceCleanupTest < Minitest::Test
        def setup
          @original_ui = Object.const_get(:UI) if Object.const_defined?(:UI)
          Object.send(:remove_const, :UI) if Object.const_defined?(:UI)
          Object.const_set(:UI, fake_ui)
        end

        def teardown
          Object.send(:remove_const, :UI) if Object.const_defined?(:UI)
          Object.const_set(:UI, @original_ui) if @original_ui
        end

        def test_cleanup_waits_until_recheck_process_finishes
          harness = Harness.new
          session = FakeSession.new(finished: false)
          workspace = FakeWorkspace.new
          state = { session: session, workspace: workspace, workspace_cleaned: false }

          refute harness.send(:cleanup_validation_focus_recheck_workspace, state)

          assert_equal 0, workspace.cleanup_count
          assert state[:workspace_cleanup_pending]
          assert_equal 1, UI.timers.length

          session.finished = true
          refute UI.timers.last.call

          assert_equal 1, workspace.cleanup_count
          assert state[:workspace_cleaned]
          assert_equal 1, session.close_count
          assert_equal 1, UI.stopped_timers.length
        end

        def test_terminate_recheck_process_defers_cleanup_on_timeout
          harness = Harness.new
          session = FakeSession.new(finished: false, terminate_result: false)
          workspace = FakeWorkspace.new
          state = { session: session, workspace: workspace, workspace_cleaned: false }

          harness.send(:terminate_validation_focus_recheck, state)

          assert_equal [200], session.terminated_waits
          assert_equal 0, workspace.cleanup_count
          assert state[:workspace_cleanup_pending]
        end

        def test_recheck_clears_validation_focus_highlight
          with_recheck_dependencies do |progress_class|
            harness = Harness.new
            editor_session = FakeEditorSession.new(cell_spaces: [Object.new])
            harness.instance_variable_set(:@editor_session, editor_session)

            result = harness.recheck_validation_focus_errors

            assert_equal [[], ''], editor_session.highlight_calls.first
            assert_equal [:clear_highlight, :collect_focus], editor_session.events.first(2)
            assert_equal 1, progress_class.last.clear_selection_count
            assert_equal 1, progress_class.last.show_count
            assert_equal 1, result[:cell_spaces].length
          end
        end

        def test_recheck_stops_before_dialog_when_dirty_topology_sync_fails
          with_recheck_dependencies do |progress_class|
            harness = Harness.new
            harness.instance_variable_set(:@editor_session, FakeEditorSession.new(cell_spaces: [Object.new]))
            harness.define_singleton_method(:validation_focus_topology_dirty?) { true }
            harness.define_singleton_method(:synchronize_validation_focus_topology_if_dirty) { false }

            assert_nil harness.recheck_validation_focus_errors

            assert_empty progress_class.instances
            refute harness.validation_focus_recheck_running?
            assert_match(/topology 동기화에 실패/, UI.messages.last)
          end
        end

        def test_recheck_report_create_gml_exports_full_model
          with_recheck_dependencies do |progress_class|
            harness = Harness.new
            editor_session = FakeEditorSession.new(cell_spaces: [Object.new])
            harness.instance_variable_set(:@editor_session, editor_session)
            UI.savepanel_path = File.join(Dir.pwd, 'tmp', 'focus_recheck_full_export')

            harness.recheck_validation_focus_errors
            progress_class.last.create_gml_callback.call

            assert_equal harness, FakeGmlExporter.last_indoor_model
            assert_equal false, FakeGmlExporter.last_options[:refresh_runtime_data]
            assert_equal "#{UI.savepanel_path}.gml", FakeGmlExporter.last_output_path
            assert_equal "GML exported:\n#{UI.savepanel_path}.gml", progress_class.last.result_message
          end
        end

        def test_recheck_sets_shared_validation_busy_immediately_and_ignores_duplicate_request
          with_recheck_dependencies do |progress_class|
            harness = Harness.new
            harness.instance_variable_set(:@editor_session, FakeEditorSession.new(cell_spaces: [Object.new]))

            with_current_indoor_model(harness) do
              dispatcher = Class.new { include ExportCommands }.new

              harness.recheck_validation_focus_errors
              assert harness.validation_focus_recheck_running?
              assert dispatcher.validation_operation_running?

              harness.recheck_validation_focus_errors
              assert_equal 1, progress_class.instances.length
              assert_match(/이미 실행 중/, UI.messages.last)
            end
          end
        end

        def test_duplicate_recheck_does_not_create_another_runner
          with_recheck_dependencies do |progress_class|
            harness = Harness.new
            harness.instance_variable_set(:@editor_session, FakeEditorSession.new(cell_spaces: [Object.new]))

            harness.recheck_validation_focus_errors
            progress_class.last.ready_callback.call
            assert_equal 1, FakeVal3dityRunner.instances.length

            harness.recheck_validation_focus_errors
            assert_equal 1, FakeVal3dityRunner.instances.length
          end
        end

        def test_success_invalid_and_runner_error_results_release_busy
          with_recheck_dependencies do |progress_class|
            [FakeResult.valid, FakeResult.invalid, FakeResult.error].each do |result|
              harness = Harness.new
              harness.instance_variable_set(:@editor_session, FakeEditorSession.new(cell_spaces: [Object.new]))

              harness.recheck_validation_focus_errors
              progress_class.last.ready_callback.call
              assert harness.validation_focus_recheck_running?

              FakeVal3dityRunner.instances.last.complete(result)
              refute harness.validation_focus_recheck_running?
            end
          end
        end

        def test_invalid_recheck_replaces_runtime_focus_rows_from_new_report
          with_recheck_dependencies do |progress_class|
            harness = Harness.new
            editor_session = FakeEditorSession.new(cell_spaces: [Object.new])
            harness.instance_variable_set(:@editor_session, editor_session)

            harness.recheck_validation_focus_errors
            progress_class.last.ready_callback.call
            FakeVal3dityRunner.instances.last.complete(FakeResult.invalid)

            assert_equal [%w[cell_A]], editor_session.begin_focus_calls
            row = editor_session.begin_focus_row_states.first.first
            assert_equal 'validation-error-row-0', row[:id]
            assert_equal ['A'], row[:cells]
            assert_equal ['cell_A'], row[:focus_ids]
          end
        end

        def test_gml_generation_error_releases_busy
          with_recheck_dependencies do |progress_class|
            FakeGmlExporter.raise_on_export = true
            harness = Harness.new
            harness.instance_variable_set(:@editor_session, FakeEditorSession.new(cell_spaces: [Object.new]))

            harness.recheck_validation_focus_errors
            progress_class.last.ready_callback.call

            refute harness.validation_focus_recheck_running?
            assert_equal :error, progress_class.last.result_payload[:status]
          end
        end

        def test_cancel_releases_busy_after_process_finishes
          with_recheck_dependencies do |progress_class|
            session = FakeSession.new(finished: false)
            FakeVal3dityRunner.next_session = session
            harness = Harness.new
            harness.instance_variable_set(:@editor_session, FakeEditorSession.new(cell_spaces: [Object.new]))

            harness.recheck_validation_focus_errors
            progress_class.last.ready_callback.call
            progress_class.last.cancel_callback.call

            refute harness.validation_focus_recheck_running?
            assert_equal [200], session.terminated_waits
          end
        end

        def test_cancel_timeout_keeps_busy_until_deferred_cleanup_observes_process_exit
          with_recheck_dependencies do |progress_class|
            session = FakeSession.new(finished: false, terminate_result: false)
            FakeVal3dityRunner.next_session = session
            harness = Harness.new
            harness.instance_variable_set(:@editor_session, FakeEditorSession.new(cell_spaces: [Object.new]))

            harness.recheck_validation_focus_errors
            progress_class.last.ready_callback.call
            progress_class.last.cancel_callback.call

            assert harness.validation_focus_recheck_running?
            assert_equal 1, UI.timers.length

            session.finished = true
            refute UI.timers.last.call
            refute harness.validation_focus_recheck_running?
          end
        end

        def test_mutating_commands_are_blocked_while_display_toggles_remain_available
          indoor_model = ToggleIndoorModel.new
          with_current_indoor_model(indoor_model) do
            dispatcher = BusyCommandHarness.new

            assert_nil dispatcher.convert_selected_solid_groups_to_cell_spaces
            assert_nil dispatcher.change_selected_cell_space_type
            assert_nil dispatcher.toggle_indoor_gml_editing
            assert_nil dispatcher.open_dual_overlay_scale_dialog
            assert_nil dispatcher.export_gml
            assert_nil dispatcher.check_validity

            dispatcher.toggle_geometry
            dispatcher.toggle_dual_overlay
            assert_equal 1, indoor_model.geometry_toggle_count
            assert_equal 1, indoor_model.overlay_toggle_count
          end
        end

        def test_context_menu_hides_change_type_while_validation_is_busy
          selected = Object.new
          dispatcher = BusyCommandHarness.new([selected])

          with_current_indoor_model(ToggleIndoorModel.new(editing: true)) do
            menu = FakeMenu.new
            dispatcher.add_context_menu_items(menu)

            assert_empty menu.labels
          end

          with_current_indoor_model(ToggleIndoorModel.new(editing: false)) do
            menu = FakeMenu.new
            dispatcher.add_context_menu_items(menu)

            assert_empty menu.labels
          end
        end

        def test_fix_mode_model_mutations_are_guarded_while_recheck_is_busy
          harness = Harness.new
          harness.instance_variable_set(:@validation_focus_recheck_running, true)

          refute harness.convert_selected_solid_groups_to_cell_spaces('GeneralSpace|Room')
          refute harness.set_selected_cell_space_type('GeneralSpace')
          refute harness.set_selected_cell_space_classification('GeneralSpace|Room')
          refute harness.set_selected_cell_space_storey('F01')
          refute harness.request_finish_editing
          refute harness.finish_editing
        end

        def test_progress_window_close_releases_busy_after_process_termination
          with_recheck_dependencies do |progress_class|
            session = FakeSession.new(finished: false)
            FakeVal3dityRunner.next_session = session
            harness = Harness.new
            harness.instance_variable_set(:@editor_session, FakeEditorSession.new(cell_spaces: [Object.new]))

            harness.recheck_validation_focus_errors
            progress_class.last.ready_callback.call
            assert_equal :close, progress_class.last.request_close_callback.call

            refute harness.validation_focus_recheck_running?
            assert_equal [200], session.terminated_waits
          end
        end

        def test_progress_window_close_before_ready_prevents_runner_start
          with_recheck_dependencies do |progress_class|
            harness = Harness.new
            harness.instance_variable_set(:@editor_session, FakeEditorSession.new(cell_spaces: [Object.new]))

            harness.recheck_validation_focus_errors
            assert_equal :close, progress_class.last.request_close_callback.call
            progress_class.last.ready_callback.call

            refute harness.validation_focus_recheck_running?
            assert_empty FakeVal3dityRunner.instances
          end
        end

        private

        def with_recheck_dependencies
          converter = IndoorGmlConverter
          replacements = {
            ExportProgressDialog: FakeExportProgressDialog,
            ValidationRunWorkspace: FakeValidationRunWorkspace,
            GmlExporter: FakeGmlExporter,
            Val3dityRunner: FakeVal3dityRunner
          }
          originals = replacements.each_with_object({}) do |(name, value), memo|
            existed = converter.const_defined?(name, false)
            original = existed ? converter.const_get(name, false) : nil
            memo[name] = [existed, original]
            converter.send(:remove_const, name) if existed
            converter.const_set(name, value)
          end
          FakeExportProgressDialog.reset
          FakeGmlExporter.reset
          FakeVal3dityRunner.reset
          yield FakeExportProgressDialog
        ensure
          replacements&.each_key do |name|
            converter.send(:remove_const, name) if converter.const_defined?(name, false)
            existed, original = originals[name]
            converter.const_set(name, original) if existed
          end
        end

        def with_current_indoor_model(indoor_model)
          singleton = IndoorModel.singleton_class
          had_current = singleton.instance_methods(false).include?(:current)
          original = singleton.instance_method(:current) if had_current
          singleton.send(:define_method, :current) { indoor_model }
          yield
        ensure
          singleton.send(:remove_method, :current) if singleton.instance_methods(false).include?(:current)
          singleton.send(:define_method, :current, original) if had_current
        end

        def fake_ui
          Class.new do
            @timers = []
            @messages = []
            @savepanel_path = nil
            @stopped_timers = []
            class << self
              attr_reader :timers
              attr_reader :messages
              attr_accessor :savepanel_path
              attr_reader :stopped_timers

              def start_timer(_interval, _repeat, &block)
                @timers << block
              end

              def stop_timer(timer_id)
                @stopped_timers << timer_id
                true
              end

              def savepanel(_title, _directory, _filter)
                @savepanel_path
              end

              def messagebox(message)
                @messages << message
              end
            end
          end
        end

        class Harness
          include IndoorModel::EditorControl

          attr_reader :states
          attr_reader :transitions

          def initialize
            @states = []
            @transitions = []
          end
        end

        class FakeEditorSession
          attr_reader :highlight_calls
          attr_reader :finish_count
          attr_reader :selection_changed_count
          attr_reader :events
          attr_reader :begin_focus_calls
          attr_reader :begin_focus_row_states

          def initialize(cell_spaces:, editing: false)
            @focus = { cell_spaces: cell_spaces, states: [], transitions: [] }
            @highlight_calls = []
            @editing = editing
            @finish_count = 0
            @selection_changed_count = 0
            @events = []
            @begin_focus_calls = []
            @begin_focus_row_states = []
          end

          def begin_validation_focus_editing(cell_ids, row_states: nil)
            @begin_focus_calls << cell_ids
            @begin_focus_row_states << Array(row_states)
            true
          end

          def validation_focus_elements
            @events << :collect_focus
            @focus
          end

          def set_validation_focus_highlight(ids, code)
            @events << :clear_highlight if ids.empty?
            @highlight_calls << [ids, code]
            true
          end

          def editing?
            @editing == true
          end

          def finish
            @finish_count += 1
            @editing = false
            true
          end

          def selection_changed
            @selection_changed_count += 1
          end
        end

        class FakeExportProgressDialog
          class << self
            attr_reader :last
            attr_reader :instances

            def active
              nil
            end

            def reset
              @last = nil
              @instances = []
            end

            def last=(value)
              @last = value
            end
          end

          attr_reader :show_count
          attr_reader :create_gml_callback
          attr_reader :result_message
          attr_reader :cancel_callback
          attr_reader :request_close_callback
          attr_reader :ready_callback
          attr_reader :result_payload
          attr_reader :clear_selection_count

          def initialize
            self.class.last = self
            self.class.instances << self
            @show_count = 0
            @clear_selection_count = 0
          end

          def clear_validation_focus_selection
            @clear_selection_count += 1
          end

          def on_create_gml(&block)
            @create_gml_callback = block
          end

          def on_cancel(&block)
            @cancel_callback = block
          end

          def on_request_close(&block)
            @request_close_callback = block
          end

          def on_ready(&block)
            @ready_callback = block
          end

          def on_open_report(&block)
            @open_report_callback = block
          end

          def show
            @show_count += 1
          end

          def set_result_message(message)
            @result_message = message
          end

          def running(_step); end

          def detail(_step, **_payload); end

          def complete(_step); end

          def fail(_step); end

          def result(payload)
            @result_payload = payload
          end

          def show_report(_path); end
        end

        class FakeValidationRunWorkspace
          def self.create(base_dir:)
            FakeWorkspace.new
          end
        end

        class FakeGmlExporter
          class << self
            attr_reader :last_indoor_model
            attr_reader :last_options
            attr_reader :last_output_path
            attr_accessor :raise_on_export

            def new(indoor_model, **options)
              @last_indoor_model = indoor_model
              @last_options = options
              allocate
            end

            def reset
              @last_indoor_model = nil
              @last_options = nil
              @last_output_path = nil
              @raise_on_export = false
            end

            def record_output_path(path)
              @last_output_path = path
            end
          end

          def self.output_root
            'tmp'
          end

          def export(output_path:)
            raise 'GML generation failed' if self.class.raise_on_export

            self.class.record_output_path(output_path)
            output_path
          end
        end

        class FakeWorkspace
          attr_reader :cleanup_count
          attr_reader :gml_path
          attr_reader :root_dir

          def initialize
            @cleanup_count = 0
            @gml_path = File.join('tmp', 'focus-recheck.gml')
            @root_dir = 'tmp'
          end

          def cleanup
            @cleanup_count += 1
            true
          end
        end

        class FakeSession
          attr_accessor :finished
          attr_reader :terminated_waits
          attr_reader :close_count

          def initialize(finished:, terminate_result: true)
            @finished = finished
            @terminate_result = terminate_result
            @terminated_waits = []
            @close_count = 0
          end

          def finished?
            @finished == true
          end

          def terminate(wait_ms:)
            @terminated_waits << wait_ms
            @finished = true if @terminate_result
            @terminate_result
          end

          def join_reader; end

          def close
            @close_count += 1
          end
        end

        class FakeVal3dityRunner
          STRICT_OVERLAP_TOL = 0.0
          TERMINATE_WAIT_MS = 200

          class << self
            attr_reader :instances
            attr_accessor :next_session

            def reset
              @instances = []
              @next_session = nil
            end
          end

          def initialize(*_args, **_options)
            self.class.instances << self
          end

          def start(progress:, &block)
            @callback = block
            self.class.next_session || FakeSession.new(finished: false)
          end

          def complete(result)
            @callback.call(result)
          end
        end

        class FakeResult
          def self.valid
            new(valid: true)
          end

          def self.invalid
            new(
              valid: false,
              report: {
                'features' => [
                  {
                    'id' => 'cell_A',
                    'errors' => [
                      { 'code' => 302, 'description' => 'Invalid cell_A' }
                    ],
                    'primitives' => []
                  }
                ]
              }
            )
          end

          def self.error
            new(valid: false, error: RuntimeError.new('runner failed'))
          end

          def initialize(valid:, error: nil, report: {})
            @valid = valid
            @error = error
            @report = report
          end

          def valid?
            @valid
          end

          def error?
            !@error.nil?
          end

          attr_reader :error
          attr_reader :report

          def report_html_path
            'tmp/report.html'
          end
        end

        class BusyCommandHarness
          include ExportCommands
          include CellSpaceCommands
          include DisplayCommands

          def initialize(selected = [])
            @selected = selected
          end

          def validation_operation_running?
            true
          end

          def update_geometry_command; end

          def update_dual_overlay_command; end

          def selected_indoor_gml_entities
            @selected
          end

          def indoor_feature(_entity)
            'CellSpace'
          end

          def cell_space_type_change_available?(_cell_spaces)
            raise 'type availability should not be evaluated while busy'
          end
        end

        class ToggleIndoorModel
          attr_reader :geometry_toggle_count
          attr_reader :overlay_toggle_count

          def initialize(editing: false)
            @editing = editing
            @geometry_toggle_count = 0
            @overlay_toggle_count = 0
          end

          def editing?
            @editing
          end

          def toggle_geometry_visible
            @geometry_toggle_count += 1
          end

          def toggle_dual_overlay_visible
            @overlay_toggle_count += 1
          end
        end

        class FakeMenu
          attr_reader :labels

          def initialize
            @labels = []
          end

          def add_item(label)
            @labels << label
          end
        end
      end
    end
  end
end
