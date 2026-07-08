# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/validity/val3dity_report_schema'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityReportSchemaTest < Minitest::Test
          Schema = Val3dityReportSchema

          def test_error_item_rows_preserve_val3dity_contexts
            report = {
              'input_file' => 'sample.gml',
              'dataset_errors' => [
                { 'code' => '203', 'description' => 'dataset failed' }
              ],
              'features' => [
                {
                  'id' => 'cell_A',
                  'errors' => [
                    { 'code' => 701, 'description' => 'feature cell_A cell_B' }
                  ],
                  'primitives' => [
                    {
                      'id' => 'state_A',
                      'errors' => [
                        { 'code' => 'E701', 'type' => 'primitive transition_A' }
                      ]
                    }
                  ]
                }
              ]
            }

            rows = Schema.error_item_rows(report)

            assert_equal ['Dataset', 'Feature', 'Primitive'], rows.map { |row| row[:scope] }
            assert_equal ['203', 701, 'E701'], rows.map { |row| row[:code] }
            assert_equal 'primitive transition_A', rows.last[:description]
          end

          def test_error_kind_rows_count_by_original_code_key
            report = {
              'input_file' => 'sample.gml',
              'dataset_errors' => [
                { 'code' => '203', 'description' => 'a' },
                { 'code' => '203', 'description' => 'b' },
                { 'code' => 701, 'description' => 'c' }
              ]
            }

            rows = Schema.error_kind_rows(report)

            assert_equal [
              { code: '203', description: 'b', count: 2 },
              { code: 701, description: 'c', count: 1 }
            ], rows
          end

          def test_refs_are_extracted_only_from_canonical_row_item
            row = {
              item: 'cell_A and cell_B',
              description: 'state_A transition_A',
              raw: { 'details' => 'cell_C state_B transition_B' }
            }

            refs = Schema.report_error_row_refs(row)

            assert_equal %w[cell_A cell_B], refs[:cells]
            assert_equal [], refs[:states]
            assert_equal [], refs[:transitions]
          end

          def test_feature_error_refs_use_feature_id_only
            report = {
              'features' => [
                {
                  'id' => 'A',
                  'errors' => [
                    {
                      'id' => 'cell_B',
                      'code' => 302,
                      'description' => 'feature mentions cell_C state_A transition_A',
                      'details' => 'cell_D'
                    }
                  ],
                  'primitives' => []
                }
              ]
            }

            row = Schema.error_item_rows(report).first
            refs = Schema.report_error_row_refs(row)

            assert_equal ['cell_A'], refs[:cells]
            assert_equal [], refs[:states]
            assert_equal [], refs[:transitions]
          end

          def test_primitive_error_refs_include_parent_feature_cell
            report = {
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
                }
              ]
            }

            row = Schema.error_item_rows(report).first
            refs = Schema.report_error_row_refs(row)

            assert_equal ['cell_A'], refs[:cells]
          end

          def test_primitive_error_refs_do_not_use_solid_item_without_parent_feature
            report = {
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

            row = Schema.error_item_rows(report).first
            refs = Schema.report_error_row_refs(row)

            assert_equal [], refs[:cells]
            assert_equal [], refs[:states]
            assert_equal [], refs[:transitions]
          end

          def test_state_and_transition_feature_refs_are_kept_for_runtime_expansion
            report = {
              'features' => [
                {
                  'id' => 'state_A',
                  'errors' => [{ 'code' => 901, 'description' => 'mentions cell_A' }],
                  'primitives' => []
                },
                {
                  'id' => 'transition_B',
                  'errors' => [{ 'code' => 902, 'description' => 'mentions cell_B' }],
                  'primitives' => []
                }
              ]
            }

            refs = Schema.final_error_refs(report)

            assert_equal [], refs[:cells]
            assert_equal ['state_A'], refs[:states]
            assert_equal ['transition_B'], refs[:transitions]
          end

          def test_dataset_error_refs_use_explicit_row_item_only
            row = Schema.error_row(
              'Dataset',
              'cell_A state_A transition_A',
              {
                'code' => 203,
                'description' => 'mentions cell_B state_B transition_B',
                'details' => 'cell_C'
              }
            )

            refs = Schema.report_error_row_refs(row)

            assert_equal ['cell_A'], refs[:cells]
            assert_equal ['state_A'], refs[:states]
            assert_equal ['transition_A'], refs[:transitions]
          end

          def test_final_error_refs_use_kept_overlap_recheck_cells_before_broad_raw_refs
            report = {
              'features' => [
                {
                  'id' => 'cell_A',
                  'errors' => [
                    {
                      'code' => 701,
                      'description' => 'overlap cell_A cell_B cell_C cell_D state_A transition_A'
                    }
                  ],
                  'primitives' => []
                }
              ],
              Schema::OVERLAP_RECHECK_REPORT_KEY => [
                {
                  'code' => 701,
                  'cells' => %w[cell_A cell_B],
                  'tolerated' => false,
                  'status' => 'kept'
                }
              ]
            }

            refs = Schema.final_error_refs(report)
            row_refs = Schema.final_error_row_refs(Schema.error_item_rows(report).first, report)

            assert_equal %w[cell_A cell_B], refs[:cells]
            assert_equal %w[cell_A cell_B], row_refs[:cells]
            assert_equal [], row_refs[:states]
            assert_equal [], row_refs[:transitions]
          end

          def test_overlap_recheck_row_prefers_pair_containing_canonical_feature_id
            report = {
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
              Schema::OVERLAP_RECHECK_REPORT_KEY => [
                {
                  'code' => 701,
                  'cells' => %w[cell_C cell_D],
                  'tolerated' => false
                },
                {
                  'code' => 701,
                  'cells' => %w[cell_A cell_B],
                  'tolerated' => false
                }
              ]
            }

            row_refs = Schema.final_error_row_refs(Schema.error_item_rows(report).first, report)

            assert_equal %w[cell_A cell_B], row_refs[:cells]
          end

          def test_overview_counts_tolerate_nil
            assert_equal 0, Schema.total_count(nil)
            assert_equal 5, Schema.total_count([{ 'total' => 2 }, { 'total' => '3' }])
            assert_equal 3, Schema.valid_count([{ 'valid' => 1 }, { 'valid' => '2' }])
            assert_equal 2, Schema.invalid_count([{ 'total' => 5, 'valid' => 3 }])
          end
        end
      end
    end
  end
end
