# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/validity/val3dity_report_renderer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityReportRendererTest < Minitest::Test
          def test_render_preserves_report_actions_and_validation_focus_data
            report = {
              'validity' => false,
              'val3dity_version' => '2.2.0',
              'time' => '2026-07-01T00:00:00',
              'features_overview' => [{ 'total' => 1, 'valid' => 0 }],
              'primitives_overview' => [{ 'total' => 1, 'valid' => 0 }],
              'parameters' => {},
              'features' => [
                {
                  'id' => 'cell_A',
                  'errors' => [
                    {
                      'code' => 701,
                      'description' => 'overlap between cell_A and cell_B state_A transition_A'
                    }
                  ],
                  'primitives' => []
                }
              ],
              'indoorgml_modeler_overlap_recheck' => [
                {
                  'code' => 701,
                  'cells' => %w[cell_A cell_B],
                  'status' => 'kept',
                  'tolerated' => false,
                  'distance_mm' => 0.1,
                  'reason' => 'kept'
                }
              ]
            }

            html = Val3dityReportRenderer.new.render(report)

            assert_includes html, 'sketchup.fixValidationErrors'
            assert_includes html, 'sketchup.createGml'
            assert_includes html, 'sketchup.focusValidationCells'
            assert_includes html, 'class="recheck-row validation-error-row c700"'
            assert_includes html, 'data-code="701"'
            assert_includes html, 'data-cells="cell_A,cell_B"'
            assert_includes html, 'data-states=""'
            assert_includes html, 'data-transitions=""'
            assert_includes html, '701 (1)'
          end

          def test_render_hides_fix_action_for_valid_report
            html = Val3dityReportRenderer.new.render(
              'validity' => true,
              'features_overview' => [],
              'primitives_overview' => [],
              'parameters' => {},
              'indoorgml_modeler_validation_status' => 'exact_valid'
            )

            refute_includes html, 'sketchup.fixValidationErrors'
            assert_includes html, 'VALID'
          end

          def test_render_maps_primitive_solid_id_to_cell_focus_data
            html = Val3dityReportRenderer.new.render(
              'validity' => false,
              'features_overview' => [{ 'total' => 1, 'valid' => 0 }],
              'primitives_overview' => [{ 'total' => 1, 'valid' => 0 }],
              'parameters' => {},
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
            )

            assert_includes html, 'Primitive solid_cell_b67d90rs'
            assert_includes html, 'data-cells="cell_b67d90rs"'
          end
        end
      end
    end
  end
end
