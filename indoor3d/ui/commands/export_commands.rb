# frozen_string_literal: true

require 'fileutils'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ExportCommands
        def create_temp_indoorgml
          begin
            output_path = IndoorGmlConverter::GmlExporter.new(IndoorModel.current).export
            UI.messagebox("IndoorGML temp.gml created:\n#{output_path}")
          rescue StandardError => e
            UI.messagebox("IndoorGML temp.gml creation failed:\n#{e.message}")
          end
        end

        def export_gml
          path = UI.savepanel('Export GML', '~', 'IndoorGML Files|*.gml;||')
          return if path.to_s.empty?

          path = "#{path}.gml" unless File.extname(path).downcase == '.gml'
          FileUtils.mkdir_p(File.dirname(path))
          IndoorGmlConverter::GmlExporter.new(IndoorModel.current).export(output_path: path)
          UI.messagebox("GML exported:\n#{path}")
        rescue StandardError => e
          UI.messagebox("GML export failed:\n#{e.message}")
        end

        def check_validity
          progress = IndoorGmlConverter::ExportProgressDialog.new
          progress.show
          UI.start_timer(0.1, false) do
            perform_check_validity(progress)
          end
        rescue StandardError => e
          progress&.close
          UI.messagebox("IndoorGML validity check failed:\n#{e.message}")
        end

        def perform_check_validity(progress)
          current_step = :runtime
          begin
            indoor_model = IndoorModel.current
            current_step = :runtime
            progress.running(:runtime)
            indoor_model.refresh_runtime_data
            progress.complete(:runtime)

            current_step = :temp_file
            progress.running(:temp_file)
            temp_path = IndoorGmlConverter::GmlExporter.new(
              indoor_model,
              refresh_runtime_data: false
            ).export
            progress.complete(:temp_file)
            validator = IndoorGmlConverter::Val3dityRunner.new(temp_path)

            current_step = :val3dity
            if validator.validate(progress: progress)
              progress&.close
              unless UI.messagebox("IndoorGML validation succeeded.\nExport GML now?", MB_YESNO) == IDYES
                return
              end

              path = UI.savepanel('Export GML', '~', 'IndoorGML Files|*.gml;||')
              return if path.to_s.empty?

              path = "#{path}.gml" unless File.extname(path).downcase == '.gml'
              FileUtils.mkdir_p(File.dirname(path))
              FileUtils.cp(temp_path, path)
              UI.messagebox("GML exported:\n#{path}")
            else
              progress&.close
              if UI.messagebox("IndoorGML validation failed.\nOpen validation report?", MB_YESNO) == IDYES
                open_local_file(validator.report_html_path)
              end
              if UI.messagebox('Open temporary GML file?', MB_YESNO) == IDYES
                open_local_file(temp_path)
              end
            end
          rescue StandardError => e
            progress&.fail(current_step)
            UI.messagebox("IndoorGML validity check failed:\n#{e.message}")
          ensure
            progress&.close
          end
        end

        def open_local_file(path)
          UI.openURL("file:///#{File.expand_path(path).tr('\\', '/')}")
        end
      end
    end
  end
end
