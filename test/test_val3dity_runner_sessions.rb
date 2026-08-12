# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

require_relative '../indoor3d/utils/geometry'
require_relative '../indoor3d/validity/val3dity_runner'

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

          def test_runner_default_overlap_tolerance_is_strict
            runner = Val3dityRunner.new(__FILE__)

            assert_equal Val3dityRunner::STRICT_OVERLAP_TOL, Val3dityRunner::DEFAULT_OVERLAP_TOL
            assert_equal Val3dityRunner::STRICT_OVERLAP_TOL, runner.instance_variable_get(:@overlap_tol)
          end

          def test_result_exposes_three_validation_outcomes
            result_class = Val3dityRunner::Val3dityResult
            paths = { report_json_path: nil, report_html_path: nil, error: nil }

            valid = result_class.new(valid: true, report: { 'indoorgml_modeler_validation_status' => 'valid' }, **paths)
            invalid = result_class.new(valid: false, report: { 'indoorgml_modeler_validation_status' => 'invalid' }, **paths)
            failed = result_class.new(valid: false, report: nil, **paths.merge(error: RuntimeError.new('boom')))

            assert_equal :valid, valid.outcome
            assert_equal :invalid, invalid.outcome
            assert_equal :failed, failed.outcome
          end

          def test_701_boundary_contact_reason_is_preserved_when_suppressed
            runner = Val3dityRunner.allocate
            runner.instance_variable_set(:@indoor_model, FakeIndoorModel.new(nil))
            runner.instance_variable_set(
              :@overlap_geometry_rechecker,
              Struct.new(:candidate) do
                def best_candidate(_candidates, _code)
                  candidate
                end
              end.new(:shared_face)
            )
            analysis = {
              intersection: {
                status: :not_reproduced,
                reason: 'BOUNDARY_CONTACT_ONLY',
                volume: 0.0,
                component_count: 1
              },
              adjacency_candidates: [:candidate]
            }

            decision = runner.send(:overlap_recheck_701_decision, analysis)

            assert_equal true, decision[:tolerated]
            assert_equal 'suppressed', decision[:status]
            assert_equal 'BOUNDARY_CONTACT_ONLY', decision[:reason]
            assert_equal 0.0, decision[:actual_overlap_volume]
          end

          def test_701_vertical_prism_reason_and_volume_are_preserved_when_kept
            runner = Val3dityRunner.allocate
            runner.instance_variable_set(:@indoor_model, FakeIndoorModel.new(nil))
            runner.instance_variable_set(
              :@overlap_geometry_rechecker,
              Struct.new(:candidate) do
                def best_candidate(_candidates, _code)
                  candidate
                end
              end.new(nil)
            )
            analysis = {
              intersection: {
                status: :reproduced,
                reason: 'REPRODUCED_AS_VERTICAL_PRISM_INTERSECTION',
                volume: 50.0,
                component_count: nil
              },
              adjacency_candidates: []
            }

            decision = runner.send(:overlap_recheck_701_decision, analysis)

            assert_equal false, decision[:tolerated]
            assert_equal 'kept', decision[:status]
            assert_equal 'REPRODUCED_AS_VERTICAL_PRISM_INTERSECTION', decision[:reason]
            assert_equal 50.0, decision[:actual_overlap_volume]
            assert_equal true, decision[:sketchup_intersection_reproduced]
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
