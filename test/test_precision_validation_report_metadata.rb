# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityReportSchema
          OVERLAP_RECHECK_REPORT_KEY = 'indoorgml_modeler_overlap_recheck'
          STRICT_VALIDITY_KEY = 'strict_val3dity_validity'
          VALIDATION_STATUS_KEY = 'indoorgml_modeler_validation_status'
          STRICT_ERRORS_REPORT_KEY = 'indoorgml_modeler_strict_errors'
        end

        class FakePolicy
          def preserve_strict_validation!(raw_report)
            raw_report[Val3dityReportSchema::STRICT_VALIDITY_KEY] =
              raw_report['validity'] == true
            raw_report[Val3dityReportSchema::STRICT_ERRORS_REPORT_KEY] = []
          end
        end

        class Val3dityRunner
          def initialize(profile)
            @validation_profile = profile
          end

          private

          def precision_validation_profile?
            @validation_profile == :precision
          end

          def overlap_recheck_policy
            @policy ||= FakePolicy.new
          end

          def preserve_strict_validation!(raw_report)
            raw_report['base_called'] = true
            raw_report
          end
        end
      end

      module PrecisionValidation
        def self.install_precision_report_metadata!
          runner_class = IndoorGmlConverter::Val3dityRunner
          unless runner_class.ancestors.include?(PrecisionReportMetadataPatch)
            runner_class.prepend(PrecisionReportMetadataPatch)
          end
        end
      end
    end
  end
end

require_relative '../indoor3d/application/precision_validation/report_metadata'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationReportMetadataTest < Minitest::Test
        def test_precision_valid_report_uses_raw_val3dity_status_without_recheck_rows
          runner = IndoorGmlConverter::Val3dityRunner.new(:precision)
          report = {
            'validity' => true,
            'indoorgml_modeler_overlap_recheck' => [{ 'tolerated' => true }]
          }

          runner.send(:preserve_strict_validation!, report)

          assert_equal true, report['strict_val3dity_validity']
          assert_equal 'valid', report['indoorgml_modeler_validation_status']
          refute report.key?('indoorgml_modeler_overlap_recheck')
          refute report.key?('base_called')
        end

        def test_precision_invalid_report_remains_invalid_without_recheck_rewrite
          runner = IndoorGmlConverter::Val3dityRunner.new(:precision)
          report = { 'validity' => false }

          runner.send(:preserve_strict_validation!, report)

          assert_equal false, report['strict_val3dity_validity']
          assert_equal 'invalid', report['indoorgml_modeler_validation_status']
        end

        def test_fast_profile_delegates_to_existing_pipeline
          runner = IndoorGmlConverter::Val3dityRunner.new(:fast)
          report = { 'validity' => true }

          runner.send(:preserve_strict_validation!, report)

          assert_equal true, report['base_called']
          refute report.key?('strict_val3dity_validity')
        end
      end
    end
  end
end
