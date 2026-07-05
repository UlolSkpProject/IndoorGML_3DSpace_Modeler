# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

require_relative '../indoor3d/utils/geometry'
require_relative '../indoor3d/export/val3dity_runner'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        unless const_defined?(:GmlExporter, false)
          class GmlExporter
            def self.output_root
              Dir.tmpdir
            end
          end
        end

        class Val3dityRunnerSessionsTest < Minitest::Test
          def setup
            reset_sessions
          end

          def teardown
            reset_sessions
          end

          def test_terminate_for_model_only_terminates_matching_sessions
            model_a = Object.new
            model_b = Object.new
            session_a = FakeSession.new
            session_b = FakeSession.new

            Val3dityRunner.register_session(
              session_a,
              owner_key: Val3dityRunner.owner_key_for_model(model_a)
            )
            Val3dityRunner.register_session(
              session_b,
              owner_key: Val3dityRunner.owner_key_for_model(model_b)
            )

            Val3dityRunner.terminate_for_model(model_a, wait_ms: 0)

            assert_equal [0], session_a.terminated_waits
            assert_empty session_b.terminated_waits
            assert_equal [session_b], Val3dityRunner.active_sessions
          end

          def test_terminate_all_clears_sessions_and_owner_keys
            model = Object.new
            session = FakeSession.new
            Val3dityRunner.register_session(
              session,
              owner_key: Val3dityRunner.owner_key_for_model(model)
            )

            Val3dityRunner.terminate_all(wait_ms: 7)

            assert_equal [7], session.terminated_waits
            assert_empty Val3dityRunner.active_sessions
            assert_empty Val3dityRunner.session_owner_keys
          end

          def test_runner_uses_indoor_model_as_session_owner
            model = Object.new
            indoor_model = FakeIndoorModel.new(model)
            runner = Val3dityRunner.allocate
            runner.send(:initialize, __FILE__, indoor_model: indoor_model)
            session = FakeSession.new

            Val3dityRunner.register_session(
              session,
              owner_key: runner.instance_variable_get(:@owner_key)
            )
            Val3dityRunner.terminate_for_model(model, wait_ms: 0)

            assert_equal [0], session.terminated_waits
          end

          def test_runner_uses_explicit_work_dir_for_report_paths
            Dir.mktmpdir('val3dity-runner-work-dir-') do |work_dir|
              runner = Val3dityRunner.new(__FILE__, work_dir: work_dir, report_name: 'report')

              assert_equal File.join(work_dir, 'report.json'), runner.report_json_path
              assert_equal File.join(work_dir, 'report', 'report.html'), runner.report_html_path
            end
          end

          private

          def reset_sessions
            Val3dityRunner.instance_variable_set(:@active_sessions, [])
            Val3dityRunner.instance_variable_set(:@session_owner_keys, {})
          end

          FakeIndoorModel = Struct.new(:model)

          class FakeSession
            attr_reader :terminated_waits

            def initialize
              @terminated_waits = []
            end

            def terminate(wait_ms:)
              @terminated_waits << wait_ms
            end
          end
        end
      end
    end
  end
end
