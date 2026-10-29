# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/validity/val3dity_report_renderer'

class Val3dityReportRendererTest < Minitest::Test
  Renderer = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityReportRenderer

  def test_groups_rows_by_error_code_with_bulk_and_row_fix_buttons
    html = Renderer.new.render(report_with_errors)

    supported_codes = [102, 104, 203, 303, 307, 701]
    all_codes = [102, 104, 201, 203, 204, 206, 303, 306, 307, 405, 701]
    row_button_codes = html.scan(/class="fix-attempt row-fix-attempt"[^>]*data-code="(\d+)"/).flatten.map(&:to_i)
    bulk_button_codes = html.scan(/class="fix-attempt bulk-fix-attempt"[^>]*data-code="(\d+)"/).flatten.map(&:to_i)
    card_codes = html.scan(/class="error-code-card [^"]*" data-code="(\d+)"/).flatten.map(&:to_i)
    assert_equal supported_codes, row_button_codes.sort
    assert_equal supported_codes, bulk_button_codes.sort
    assert_equal all_codes, card_codes.sort
    assert_equal all_codes.length, html.scan(/class="error-code-card /).length
    assert_includes html, '>일괄 수정 시도</button>'
    assert_includes html, 'grid-template-columns: minmax(0, 1fr) minmax(110px, 1.4fr) minmax(0, 1fr);'
    assert_includes html, '.error-code-heading { grid-column: 1;'
    assert_includes html, '.error-code-label { grid-column: 2;'
    assert_match(/<span class="error-code-heading">\s*<span class="toggle-triangle"[^>]*><\/span>\s*<span class="code-badge c100">102<\/span>\s*<span class="error-code-count">1건<\/span>/, html)
    assert_includes html, '<span class="error-code-label" title="겹쳐진 인접 꼭지점">겹쳐진 인접 꼭지점</span>'
    assert_includes html, '<span class="error-code-label" title="평면 내 꼭지점 높이 편차">평면 내 꼭지점 높이 편차</span>'
    assert_includes html, '<span class="error-code-label" title="면 뒤틀림">면 뒤틀림</span>'
    assert_includes html, '<span class="error-code-label" title="솔리드 내 자기 교차">솔리드 내 자기 교차</span>'
    assert_includes html, 'sketchup.attemptValidationFix(code, rowId);'
    assert_includes html, "card.querySelectorAll('.row-fix-attempt:not(:disabled)')"
    assert_includes html, 'rowButton.click();'
    refute_includes html, "beginValidationFixAttempt(button, code, '');"
    assert_includes html, 'var validationBulkFixAttempts = {};'
    assert_includes html, 'function validationFixFailureReasons(payload)'
    assert_includes html, 'function completeValidationBulkFixAttempt(payload, succeeded)'
    assert_includes html, "attempt.failureReasons.push(label + ': ' + reason);"
    assert_includes html, "feedbackLines.push('• ' + reason);"
    assert_includes html, 'feedbackMessage: feedbackLines.join'
    assert_includes html, 'failureReasons: []'
    assert_includes html, 'if (!completeValidationBulkFixAttempt(payload, succeeded))'
    assert_includes html, 'window.completeValidationFixAttempt = function(payload)'
    assert_includes html, "button.classList.add(succeeded ? 'is-success' : 'is-failure');"
    assert_includes html, "button.textContent = succeeded ? '성공' : '실패';"
    assert_includes html, 'updateBulkFixButtonState(code);'
    assert_includes html, 'button.disabled = true;'
    assert_includes html, 'opacity: .45;'
    assert_includes html, 'id="validation-fix-messagebox"'
    assert_includes html, 'role="alertdialog"'
    assert_includes html, 'function showValidationFixMessagebox(payload)'
    assert_includes html, 'var effectiveFailed = failed + skipped;'
    assert_includes html, 'showValidationFixMessagebox(payload);'
    assert_includes html, "title.textContent = payload.feedbackTitle || '자동 수정 결과';"
    assert_includes html, "body.textContent = payload.feedbackMessage || payload.message || '';"
  end

  def test_repeated_code_uses_one_collapsible_card_with_multiple_rows
    html = Renderer.new.render(report_with_repeated_code)

    assert_equal 1, html.scan(/class="error-code-card c200" data-code="203"/).length
    assert_equal 1, html.scan(/class="fix-attempt bulk-fix-attempt"[^>]*data-code="203"/).length
    assert_equal 2, html.scan(/class="fix-attempt row-fix-attempt"[^>]*data-code="203"/).length
    assert_match(/<span class="error-code-count">2건<\/span>/, html)
  end

  def test_excludes_non_indoor_gml_600_series_errors
    report = report_with_errors
    report['features'][0]['errors'] << {
      'code' => 601,
      'description' => 'BUILDINGPARTS_OVERLAP',
      'id' => 'building_part_alpha'
    }

    html = Renderer.new.render(report)

    refute_includes html, 'data-code="601"'
    refute_includes html, 'BUILDINGPARTS_OVERLAP'
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
                },
                {
                  'code' => 102,
                  'description' => 'CONSECUTIVE_POINTS_SAME',
                  'id' => 'polygon_7_cell_beta'
                },
                {
                  'code' => 204,
                  'description' => 'NON_PLANAR_POLYGON_NORMALS_DEVIATION',
                  'id' => 'polygon_8_cell_beta'
                },
                {
                  'code' => 303,
                  'description' => 'NON_MANIFOLD_CASE',
                  'id' => 'solid_cell_beta'
                },
                {
                  'code' => 307,
                  'description' => 'POLYGON_WRONG_ORIENTATION',
                  'id' => 'polygon_9_cell_beta'
                },
                {
                  'code' => 701,
                  'description' => 'CELLS_OVERLAP',
                  'id' => 'cell_alpha-cell_beta'
                }
              ]
            }
          ]
        }
      ]
    }
  end

  def report_with_repeated_code
    {
      'val3dity_version' => '2.2.0',
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
                  'code' => 203,
                  'description' => 'NON_PLANAR_POLYGON_DISTANCE_PLANE',
                  'id' => 'polygon_0_cell_alpha'
                }
              ]
            },
            {
              'id' => 'solid_cell_beta',
              'errors' => [
                {
                  'code' => 203,
                  'description' => 'NON_PLANAR_POLYGON_DISTANCE_PLANE',
                  'id' => 'polygon_1_cell_beta'
                }
              ]
            }
          ]
        }
      ]
    }
  end
end
