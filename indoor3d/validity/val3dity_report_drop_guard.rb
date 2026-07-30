# frozen_string_literal: true

require_relative 'val3dity_report_renderer'
require_relative '../ui/html_dialog_safety'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityReportDropGuard
          private

          def fallback_report_html(raw_report)
            HtmlDialogSafety.inject_external_file_drop_guard(super)
          end
        end

        Val3dityReportRenderer.prepend(Val3dityReportDropGuard) unless
          Val3dityReportRenderer.ancestors.include?(Val3dityReportDropGuard)
      end
    end
  end
end
