# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/validity/val3dity_report_renderer'

class Val3dityReportRendererTest < Minitest::Test
  Renderer = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityReportRenderer

  def test_renders_only_row_fix_attempt_buttons_with_console_logs
    html = Renderer.new.render(report_with_errors)

    assert_equal 2, html.scan('class="fix-attempt row-fix-attempt"').length
    assert_includes html, 'data-row-id="validation-error-row-0" data-code="104">수정 시도</button>'
    refute_includes html, 'data-row-id="validation-error-row-1" data-code="201">수정 시도</button>'
    assert_includes html, 'data-row-id="validation-error-row-2" data-code="203">수정 시도</button>'
    refute_includes html, 'data-row-id="validation-error-row-3" data-code="206">수정 시도</button>'
    refute_includes html, 'data-row-id="validation-error-row-4" data-code="306">수정 시도</button>'
    refute_includes html, 'data-row-id="validation-error-row-5" data-code="405">수정 시도</button>'
    assert_includes html, "console.log(rowId + '_' + code + '_수정시도');"
    assert_includes html, 'sketchup.attemptValidationFix(code, rowId);'
    assert_includes html, 'window.completeValidationFixAttempt = function(payload)'
    refute_includes html, 'bulk-fix-attempt'
    refute_includes html, '일괄 수정 시도'
  end

  private

  def report_with_errors
    {
      'val3dity_version' => '2.2.0',
      'time' => '2026-10-28 12:00:00',
      'validity' => false,
      'strict_val3dity_validity' => false,
      'indoorgml_modeler_validation_status' => 'invalid',
      'features_overview' => [{ 'total' => 1, 'valid' => 0 }],
      'primitives_overview' => [{ 'total' => 2, 'valid' => 0 }],
      'parameters' => {},
      'features' => [
        {
          'id' => 'IF_001',
          'errors' => [],
          'primitives' => [
            {
              'id' => 'solid_cell_alpha',
              'errors' => [
                {
                  'code' => 104,
                  'description' => 'RING_SELF_INTERSECTION',
                  'id' => 'polygon_0_cell_alpha'
                }
              ]
            },
            {
              'id' => 'solid_cell_beta',
              'errors' => [
                {
                  'code' => 201,
                  'description' => 'INTERSECTION_RINGS',
                  'id' => 'polygon_4_cell_beta'
                },
                {
                  'code' => 203,
                  'description' => 'NON_PLANAR_POLYGON_DISTANCE_PLANE',
                  'id' => 'polygon_5_cell_beta'
                },
                {
                  'code' => 206,
                  'description' => 'INNER_RING_OUTSIDE',
                  'id' => 'polygon_6_cell_beta'
                },
                {
                  'code' => 306,
                  'description' => 'SHELL_SELF_INTERSECTION',
                  'id' => 'solid_cell_beta'
                },
                {
                  'code' => 405,
                  'description' => 'WRONG_ORIENTATION_SHELL',
                  'id' => 'solid_cell_beta'
                }
              ]
            }
          ]
        }
      ]
    }
  end
end
