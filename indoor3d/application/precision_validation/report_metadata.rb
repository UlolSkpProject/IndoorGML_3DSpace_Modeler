# frozen_string_literal: true

require_relative '../../validity/val3dity_report_schema'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        module PrecisionReportMetadataPatch
          private

          def preserve_strict_validation!(raw_report)
            return super unless precision_validation_profile?

            overlap_recheck_policy.preserve_strict_validation!(raw_report)
            schema = IndoorGmlConverter::Val3dityReportSchema
            raw_valid = raw_report['validity'] == true
            raw_report[schema::VALIDATION_STATUS_KEY] =
              raw_valid ? 'valid' : 'invalid'
            raw_report.delete(schema::OVERLAP_RECHECK_REPORT_KEY)
            raw_report
          end
        end

        def self.install_precision_report_metadata!
          runner_class = IndoorGmlConverter::Val3dityRunner
          unless runner_class.ancestors.include?(PrecisionReportMetadataPatch)
            runner_class.prepend(PrecisionReportMetadataPatch)
          end
          true
        end
      end

      PrecisionValidation.install_precision_report_metadata!
    end
  end
end
