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
                  'actual_overlap_volume_mm3' => 2.5,
                  'intersection_component_count' => 3,
                  'reason' => 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION'
                }
              ]
            }

            html = Val3dityReportRenderer.new.render(report)

            assert_includes html, 'sketchup.fixValidationErrors'
            assert_includes html, 'sketchup.createGml'
            assert_includes html, 'sketchup.focusValidationCells'
            assert_includes html, 'sketchup.reportDomReady();'
            assert_includes html, 'class="recheck-row validation-error-row c700"'
            assert_includes html, 'data-row-id="validation-error-row-0"'
            assert_includes html, 'data-code="701"'
            assert_includes html, 'data-cells="A,B"'
            assert_includes html, 'data-states=""'
            assert_includes html, 'data-transitions=""'
            assert_includes html, '701 (1)'
            assert_includes html, '<span class="member-label">Not suppressed reason</span>'
            assert_includes html, '<span class="member-value">SketchUp Boolean에서 유효한 intersection 재현</span>'
            assert_includes html, '<span class="member-label">Overlap volume</span>'
            assert_includes html, '<span class="member-value">2.5 mm³</span>'
            refute_includes html, '<span class="member-label">Distance</span>'
            refute_includes html, '<span class="member-label">Intersection components</span>'
            assert_includes html, 'updateValidationFocusRow'
            assert_includes html, 'window.clearValidationFocusSelection = function()'
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

          def test_render_maps_primitive_solid_cell_id_without_parent_feature
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

            assert_includes html, 'title="cell_b67d90rs"'
            assert_includes html, 'data-cells="b67d90rs"'
          end

          def test_overlap_row_data_cells_use_cell_space_ids_from_error_pair
            html = Val3dityReportRenderer.new.render(
              'validity' => false,
              'features_overview' => [{ 'total' => 1, 'valid' => 0 }],
              'primitives_overview' => [{ 'total' => 0, 'valid' => 0 }],
              'parameters' => {},
              'features' => [
                {
                  'id' => 'IF_001',
                  'errors' => [
                    {
                      'code' => 701,
                      'id' => 'cell_igg7up1f and cell_ryok9vdg',
                      'description' => 'CELLS_OVERLAP'
                    }
                  ],
                  'primitives' => []
                }
              ],
              'indoorgml_modeler_overlap_recheck' => [
                {
                  'code' => 701,
                  'cells' => %w[cell_igg7up1f cell_ryok9vdg],
                  'status' => 'kept',
                  'tolerated' => false,
                  'actual_overlap_volume_mm3' => 1.0,
                  'reason' => 'kept'
                }
              ]
            )

            assert_includes html, 'cell_igg7up1f and cell_ryok9vdg'
            assert_includes html, 'data-cells="igg7up1f,ryok9vdg"'
            refute_includes html, 'data-cells="IF_001"'
          end

          def test_dual_vertex_feature_row_uses_cell_space_id_in_error_item
            html = Val3dityReportRenderer.new.render(
              'validity' => false,
              'features_overview' => [{ 'total' => 1, 'valid' => 0 }],
              'primitives_overview' => [],
              'parameters' => {},
              'features' => [
                {
                  'id' => 'IF_001',
                  'errors' => [
                    {
                      'code' => 702,
                      'id' => 'CellSpace id=cell_hw5p10tr',
                      'description' => 'DUAL_VERTEX_OUTSIDE_CELL'
                    }
                  ],
                  'primitives' => []
                }
              ]
            )

            assert_includes html, '<span class="member-value">CellSpace id=cell_hw5p10tr</span>'
            assert_includes html, 'data-code="702" data-cells="hw5p10tr"'
            refute_includes html, 'data-cells="IF_001"'
          end

          def test_render_groups_duplicate_error_cards_and_shows_member_details_and_group_counts
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
                      'id' => 'feature_error_A',
                      'code' => 203,
                      'description' => 'INVALID_SHELL',
                      'details' => '<unsafe detail>'
                    }
                  ],
                  'primitives' => [
                    {
                      'id' => 'solid_cell_A',
                      'errors' => [{ 'id' => 'primitive_error_A', 'code' => 203, 'description' => 'INVALID_SHELL' }]
                    }
                  ]
                }
              ]
            }

            html = Val3dityReportRenderer.new.render(report)

            assert_equal 1, html.scan(/<details class="recheck-row validation-error-row/).length
            assert_equal 2, html.scan(/<div class="error-member">/).length
            assert_includes html, '상세 2건'
            assert_includes html, '<span class="metric-value">1</span>'
            assert_includes html, '<span class="section-count">1건</span>'
            assert_includes html, 'data-filter="all">전체 1</button>'
            assert_includes html, 'data-filter="203">203 (1)</button>'
            assert_equal 2, html.scan('<span class="member-label">Description</span>').length
            assert_includes html, '<span class="member-value">feature_error_A</span>'
            assert_includes html, '<span class="member-value">primitive_error_A</span>'
            refute_includes html, '<span class="member-label">Scope</span>'
            refute_includes html, '<span class="member-label">Parent feature</span>'
            refute_includes html, '<span class="member-label">Details</span>'
            refute_includes html, '&lt;unsafe detail&gt;'
            refute_includes html, '<unsafe detail>'
          end

          def test_member_detail_text_is_selectable_while_select_all_remains_blocked
            html = Val3dityReportRenderer.new.render(
              'validity' => false,
              'features_overview' => [{ 'total' => 1, 'valid' => 0 }],
              'primitives_overview' => [],
              'parameters' => {},
              'features' => [
                {
                  'id' => 'cell_A',
                  'errors' => [{ 'code' => 203, 'description' => 'INVALID_SHELL' }],
                  'primitives' => []
                }
              ]
            )

            assert_includes html, "event.target.closest('.cell-name, .member-value')"
            assert_includes html, "var selectableTextSelector = '.cell-name, .member-value';"
            assert_includes html, "String(event.key).toLowerCase() === 'a'"
            assert_includes html, 'event.preventDefault();'
            assert_includes html, 'event.stopPropagation();'
          end
        end
      end
    end
  end
end
