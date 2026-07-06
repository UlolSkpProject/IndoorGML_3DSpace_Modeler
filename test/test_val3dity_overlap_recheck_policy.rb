# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/validity/val3dity_overlap_recheck_policy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityOverlapRecheckPolicyTest < Minitest::Test
          REPORT_KEY = Val3dityOverlapRecheckPolicy::REPORT_KEY

          def test_preserve_strict_validation_snapshots_original_errors
            report = sample_report
            policy = Val3dityOverlapRecheckPolicy.new(tolerance_mm: 0.01)

            policy.preserve_strict_validation!(report)

            assert_equal false, report[Val3dityOverlapRecheckPolicy::STRICT_VALIDITY_KEY]
            assert_equal [701, 704, 203], report[Val3dityOverlapRecheckPolicy::STRICT_ERRORS_REPORT_KEY].map { |row| row['code'] }
          end

          def test_apply_removes_tolerated_overlap_errors_and_refreshes_report
            report = sample_report
            policy = Val3dityOverlapRecheckPolicy.new(tolerance_mm: 0.25)
            seen = []

            policy.preserve_strict_validation!(report)
            results = policy.apply!(
              report,
              on_result: ->(result) { seen << result['status'] }
            ) do |code, cell1, cell2|
              if code == 701
                policy.recheck_result(code, [cell1, cell2], true, 'NO_VALID_INTERSECTION_GROUP_RETURNED')
              else
                policy.recheck_result(code, [cell1, cell2], false, 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION')
              end
            end

            feature = report['features'].first
            primitive = feature['primitives'].first

            assert_equal %w[suppressed kept], seen
            assert_equal %w[suppressed kept], results.map { |row| row['status'] }
            assert_equal [704], feature['errors'].map { |error| error['code'] }
            assert_equal [203], primitive['errors'].map { |error| error['code'] }
            assert_equal false, report['validity']
            assert_equal 'invalid', report[Val3dityOverlapRecheckPolicy::VALIDATION_STATUS_KEY]
            assert_equal [701, 704], report[REPORT_KEY].map { |row| row['code'] }
            assert_equal [704, 203], report['all_errors']
            assert_equal 1, report['features_overview'].first['total']
            assert_equal 0, report['features_overview'].first['valid']
            assert_equal 1, report['primitives_overview'].first['total']
            assert_equal 0, report['primitives_overview'].first['valid']
          end

          def test_apply_marks_extension_policy_valid_when_only_tolerated_errors_remain
            report = sample_report
            report['features'].first['errors'] = [
              { 'code' => 701, 'description' => 'overlap cell_A cell_B' }
            ]
            report['features'].first['primitives'].first['errors'] = []
            policy = Val3dityOverlapRecheckPolicy.new(tolerance_mm: 0.25)

            policy.preserve_strict_validation!(report)
            policy.apply!(report) do |code, cell1, cell2|
              policy.recheck_result(code, [cell1, cell2], true, 'NO_VALID_INTERSECTION_GROUP_RETURNED')
            end

            assert_empty report['features'].first['errors']
            assert_equal true, report['validity']
            assert_equal true, report[Val3dityOverlapRecheckPolicy::EXTENSION_VALIDITY_KEY]
            assert_equal 'extension_policy_valid', report[Val3dityOverlapRecheckPolicy::VALIDATION_STATUS_KEY]
          end

          def test_missing_cell_pair_is_recorded_and_kept
            report = {
              'validity' => false,
              'dataset_errors' => [
                { 'code' => 701, 'description' => 'overlap without ids' }
              ],
              'features' => [],
              'features_overview' => [],
              'primitives_overview' => []
            }
            policy = Val3dityOverlapRecheckPolicy.new(tolerance_mm: 0.25)

            results = policy.apply!(report) { raise 'pair rechecker should not be called' }

            assert_equal 1, results.length
            assert_equal false, results.first['tolerated']
            assert_equal 'cell pair not found in val3dity error', results.first['reason']
            assert_equal 1, report['dataset_errors'].length
          end

          private

          def sample_report
            {
              'validity' => false,
              'dataset_errors' => [],
              'features_overview' => [{ 'type' => 'CellSpace', 'total' => 0, 'valid' => 0 }],
              'primitives_overview' => [{ 'type' => 'Solid', 'total' => 0, 'valid' => 0 }],
              'features' => [
                {
                  'id' => 'cell_A',
                  'type' => 'CellSpace',
                  'validity' => false,
                  'errors' => [
                    { 'code' => 701, 'description' => 'overlap cell_A cell_B' },
                    { 'code' => 704, 'description' => 'adjacency cell_A cell_B' }
                  ],
                  'primitives' => [
                    {
                      'id' => 'solid_A',
                      'type' => 'Solid',
                      'validity' => false,
                      'errors' => [
                        { 'code' => 203, 'description' => 'not rechecked' }
                      ]
                    }
                  ]
                }
              ]
            }
          end
        end
      end
    end
  end
end
