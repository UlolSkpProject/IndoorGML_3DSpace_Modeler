# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        # GmlExporter validates through exportable_cell_spaces, whose snapshot is
        # lazily built on first access. Build that snapshot before entering the
        # validation stage so progress remains strictly monotonic:
        # geometry -> topology -> validation -> writer -> file.
        module GmlExporterProgressStageOrder
          private

          def validate_exportable_content!
            tracker = GmlExportProgressContext.current
            export_snapshot if tracker&.active?
            super
          end
        end
      end

      if defined?(IndoorGmlConverter::GmlExporter)
        IndoorGmlConverter::GmlExporter.prepend(
          ProductionProgress::GmlExporterProgressStageOrder
        ) unless IndoorGmlConverter::GmlExporter.ancestors.include?(
          ProductionProgress::GmlExporterProgressStageOrder
        )
      end
    end
  end
end
