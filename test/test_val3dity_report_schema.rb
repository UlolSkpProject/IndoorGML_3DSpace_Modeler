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

          def test_refs_are_extracted_from_item_description_and_raw_payload
            row = {
              item: 'cell_A and cell_B',
              description: 'state_A transition_A',
              raw: { 'details' => 'cell_C state_B transition_B' }
            }

            refs = Schema.report_error_row_refs(row)

            assert_equal %w[cell_A cell_B cell_C], refs[:cells]
            assert_equal %w[state_A state_B], refs[:states]
            assert_equal %w[transition_A transition_B], refs[:transitions]
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
