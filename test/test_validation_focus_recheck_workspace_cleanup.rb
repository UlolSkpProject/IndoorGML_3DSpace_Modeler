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
            assert_equal 1, progress_class.last.show_count
            assert_equal 1, result[:cell_spaces].length
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
            assert_equal "#{UI.savepanel_path}.gml", FakeGmlExporter.last_output_path
            assert_equal "GML exported:\n#{UI.savepanel_path}.gml", progress_class.last.result_message
          end
        end

        private

        def with_recheck_dependencies
          converter = IndoorGmlConverter
          replacements = {
            ExportProgressDialog: FakeExportProgressDialog,
            ValidationRunWorkspace: FakeValidationRunWorkspace,
            GmlExporter: FakeGmlExporter
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
          yield FakeExportProgressDialog
        ensure
          replacements&.each_key do |name|
            converter.send(:remove_const, name) if converter.const_defined?(name, false)
            existed, original = originals[name]
            converter.const_set(name, original) if existed
          end
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
        end

        class FakeEditorSession
          attr_reader :highlight_calls
          attr_reader :finish_count

          def initialize(cell_spaces:, editing: false)
            @focus = { cell_spaces: cell_spaces, states: [], transitions: [] }
            @highlight_calls = []
            @editing = editing
            @finish_count = 0
          end

          def validation_focus_elements
            @focus
          end

          def set_validation_focus_highlight(ids, code)
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
        end

        class FakeExportProgressDialog
          class << self
            attr_reader :last

            def active
              nil
            end

            def reset
              @last = nil
            end

            def last=(value)
              @last = value
            end
          end

          attr_reader :show_count
          attr_reader :create_gml_callback
          attr_reader :result_message

          def initialize
            self.class.last = self
            @show_count = 0
          end

          def on_create_gml(&block)
            @create_gml_callback = block
          end

          def on_cancel; end

          def on_request_close; end

          def on_ready; end

          def show
            @show_count += 1
          end

          def set_result_message(message)
            @result_message = message
          end
        end

        class FakeValidationRunWorkspace
          def self.create(base_dir:)
            FakeWorkspace.new
          end
        end

        class FakeGmlExporter
          class << self
            attr_reader :last_indoor_model
            attr_reader :last_output_path

            def new(indoor_model)
              @last_indoor_model = indoor_model
              allocate
            end

            def reset
              @last_indoor_model = nil
              @last_output_path = nil
            end

            def record_output_path(path)
              @last_output_path = path
            end
          end

          def self.output_root
            'tmp'
          end

          def export(output_path:)
            self.class.record_output_path(output_path)
            output_path
          end
        end

        class FakeWorkspace
          attr_reader :cleanup_count

          def initialize
            @cleanup_count = 0
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
            @terminate_result
          end

          def join_reader; end

          def close
            @close_count += 1
          end
        end
      end
    end
  end
end
