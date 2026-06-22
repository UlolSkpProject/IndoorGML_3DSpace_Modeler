# frozen_string_literal: true

require 'fileutils'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ExportCommands
        def create_temp_indoorgml
          begin
            output_path = IndoorGmlConverter::GmlExporter.new(
              IndoorModel.current
            ).export
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
          IndoorGmlConverter::GmlExporter.new(
            IndoorModel.current
          ).export(output_path: path)
          UI.messagebox("GML exported:\n#{path}")
        rescue StandardError => e
          UI.messagebox("GML export failed:\n#{e.message}")
        end

        def check_validity
          overlap_tol = prompt_validation_overlap_tol
          return if overlap_tol.nil?

          progress = IndoorGmlConverter::ExportProgressDialog.new
          state = validation_close_state
          state[:overlap_tol] = overlap_tol
          configure_validation_close_handler(progress, state)
          progress.show
          UI.start_timer(0.1, false) do
            perform_check_validity(progress, state)
          end
        rescue StandardError => e
          progress&.result(
            status: :error,
            title: 'IndoorGML validity check failed',
            message: e.message,
            actions: [:close]
          )
        end

        def perform_check_validity(progress, state = validation_close_state)
          current_step = :temp_file
          indoor_model = IndoorModel.current

          progress.running(:temp_file)
          state[:temp_file_running] = true
          temp_path = nil
          begin
            temp_path = IndoorGmlConverter::GmlExporter.new(
              indoor_model,
              refresh_runtime_data: false
            ).export
          ensure
            state[:temp_file_running] = false
          end
          progress.complete(:temp_file)
          return if state[:close_after_temp] || state[:cancelled]

          validator = IndoorGmlConverter::Val3dityRunner.new(
            temp_path,
            overlap_tol: state[:overlap_tol] || IndoorGmlConverter::Val3dityRunner::DEFAULT_OVERLAP_TOL
          )

          current_step = :val3dity
          state[:val_running] = true
          state[:val_session] = validator.start(progress: progress) do |result|
            next if state[:cancelled]

            state[:val_running] = false
            state[:completed] = true
            handle_validation_result(result, progress, temp_path)
          end
        rescue StandardError => e
          state[:val_running] = false
          state[:completed] = true
          progress&.fail(current_step)
          progress&.result(
            status: :error,
            title: 'IndoorGML validity check failed',
            message: e.message,
            actions: [:close]
          )
        end

        def validation_close_state
          {
            temp_file_running: false,
            close_after_temp: false,
            val_running: false,
            val_session: nil,
            completed: false,
            cancelled: false,
            overlap_tol: IndoorGmlConverter::Val3dityRunner::DEFAULT_OVERLAP_TOL
          }
        end

        def prompt_validation_overlap_tol
          default_value = format('%.15g', IndoorGmlConverter::Val3dityRunner::DEFAULT_OVERLAP_TOL)
          values = UI.inputbox(
            ['overlap_tol'],
            [default_value],
            'val3dity validation options'
          )
          return nil unless values

          overlap_tol = Float(values[0])
          raise ArgumentError, 'overlap_tol must be greater than or equal to 0.' if overlap_tol.negative?

          overlap_tol
        rescue ArgumentError, TypeError
          UI.messagebox('Invalid overlap_tol. Enter a number greater than or equal to 0.')
          nil
        end

        def configure_validation_close_handler(progress, state)
          progress.on_request_close do
            if state[:temp_file_running]
              state[:close_after_temp] = true
              :close
            elsif state[:val_running] && !state[:completed]
              if IndoorGmlConverter::Val3dityRunner.shutting_down?
                state[:cancelled] = true
                state[:val_running] = false
                state[:val_session]&.terminate(wait_ms: 0)
                :close
              elsif UI.messagebox("Validation is still running.\nCancel validation?", MB_YESNO) == IDYES
                state[:cancelled] = true
                state[:val_running] = false
                state[:val_session]&.terminate
                :close
              else
                :keep_open
              end
            else
              :close
            end
          end
        end

        def handle_validation_result(result, progress, temp_path)
          progress&.on_create_gml do
            create_gml_from_temp(temp_path, progress)
          end
          progress&.on_open_report do
            begin
              open_report_dialog(result.report_html_path)
            rescue StandardError => e
              progress&.set_result_message("Opening report failed:\n#{e.message}")
            end
          end

          if result.error?
            progress&.fail(:val3dity)
            progress&.result(
              status: :error,
              title: 'IndoorGML validity check failed',
              message: result.error.message,
              actions: [:close]
            )
            return
          end

          if result.valid?
            progress&.result(
              status: :success,
              title: 'IndoorGML validation succeeded',
              message: 'Validation completed. Open the report or create the GML file when ready.',
              actions: [:openReport, :createGml, :close]
            )
          else
            progress&.result(
              status: :failed,
              title: 'IndoorGML validation failed',
              message: 'Validation completed with errors. Open the report or create the GML file.',
              actions: [:openReport, :createGml, :close]
            )
          end
        rescue StandardError => e
          progress&.result(
            status: :error,
            title: 'IndoorGML validity result handling failed',
            message: e.message,
            actions: [:close]
          )
        end

        def create_gml_from_temp(temp_path, progress)
          path = UI.savepanel('Export GML', '~', 'IndoorGML Files|*.gml;||')
          if path.to_s.empty?
            progress&.set_result_message('GML export canceled.')
            return
          end

          path = "#{path}.gml" unless File.extname(path).downcase == '.gml'
          FileUtils.mkdir_p(File.dirname(path))
          FileUtils.cp(temp_path, path)
          progress&.set_result_message("GML exported:\n#{path}")
        rescue StandardError => e
          progress&.set_result_message("GML export failed:\n#{e.message}")
        end

        def open_report_dialog(path)
          raise "Report file was not found:\n#{path}" unless File.exist?(path)

          @validation_report_dialog&.close if @validation_report_dialog&.visible?
          @validation_report_dialog = UI::HtmlDialog.new(
            dialog_title: 'val3dity report',
            preferences_key: 'ULOL.Indoor3DGmlModeler.Val3dityReport',
            scrollable: true,
            resizable: true,
            width: 980,
            height: 720,
            style: UI::HtmlDialog::STYLE_DIALOG
          )
          @validation_report_dialog.set_file(File.expand_path(path))
          @validation_report_dialog.show
        end
      end
    end
  end
end
