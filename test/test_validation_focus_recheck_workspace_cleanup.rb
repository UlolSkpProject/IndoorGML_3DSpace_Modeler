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

        private

        def fake_ui
          Class.new do
            @timers = []
            class << self
              attr_reader :timers

              def start_timer(_interval, _repeat, &block)
                @timers << block
              end
            end
          end
        end

        class Harness
          include IndoorModel::EditorControl
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
