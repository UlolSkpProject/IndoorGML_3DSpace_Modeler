# frozen_string_literal: true

require 'fileutils'
require_relative '../../validity/validation_run_workspace'
require_relative '../../validity/validation_session'
require_relative '../../validity/val3dity_report_schema'
require_relative '../../validity/validation_focus_report_mapper'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ExportCommands
        def validation_operation_running?
          return true if @validation_session&.running? == true || @validation_operation_running == true

          indoor_model = IndoorModel.current
          indoor_model.respond_to?(:validation_focus_recheck_running?) && indoor_model.validation_focus_recheck_running?
        rescue StandardError
          false
        end

        def export_gml
          return if validation_operation_running?

          export_runtime_gml(IndoorModel.current)
        end

        def export_runtime_gml(indoor_model, progress = nil)
          path = UI.savepanel('Export GML', '~', 'IndoorGML Files|*.gml;||')
          if path.to_s.empty?
            progress&.set_result_message('GML export canceled.')
            return nil
          end

          path = "#{path}.gml" unless File.extname(path).downcase == '.gml'
          FileUtils.mkdir_p(File.dirname(path))
          if indoor_model.editing? && !indoor_model.finish_editing
            message = 'GML export failed: topology synchronization failed.'
            progress ? progress.set_result_message(message) : UI.messagebox(message)
            return nil
          end
          IndoorGmlConverter::GmlExporter.new(
            indoor_model
          ).export(output_path: path)
          message = "GML exported:\n#{path}"
          progress ? progress.set_result_message(message) : UI.messagebox(message)
          path
        rescue StandardError => e
          message = "GML export failed:\n#{e.message}"
          progress ? progress.set_result_message(message) : UI.messagebox(message)
          nil
        end

        def check_validity
          return if validation_operation_running?

          workspace = nil
          session = nil
          progress = nil
          if validation_dialog_visible?
            @validation_progress_dialog.bring_to_front
            return
          end

          captured_model = Sketchup.active_model
          captured_indoor_model = IndoorModel.for(captured_model)
          if captured_indoor_model.editing? && !captured_indoor_model.finish_editing
            UI.messagebox('Validity check failed: topology synchronization failed.')
            return
          end
          @validation_operation_running = true
          workspace = IndoorGmlConverter::ValidationRunWorkspace.create(
            base_dir: IndoorGmlConverter::GmlExporter.output_root
          )
          progress = IndoorGmlConverter::ExportProgressDialog.new
          @validation_progress_dialog = progress
          state = validation_close_state
          session = IndoorGmlConverter::ValidationSession.new(
            model: captured_model,
            indoor_model: captured_indoor_model,
            progress: progress,
            state: state,
            workspace: workspace,
            on_cancel: proc { |active_session, _reason| validation_session_cancelled(active_session) },
            on_complete: proc { |active_session, _reason| validation_session_completed(active_session) },
            logger: Logger
          )
          @validation_session = session
          state[:overlap_tol] = IndoorGmlConverter::Val3dityRunner::STRICT_OVERLAP_TOL
          configure_validation_close_handler(session)
          configure_validation_cancel_handler(session)
          generation = session.generation
          progress.on_ready do
            next unless session.active_generation?(generation)
            next if state[:started]

            state[:started] = true
            perform_check_validity(session)
          end
          progress.show
        rescue StandardError => e
          @validation_operation_running = false
          if session
            session.cancel(reason: :failed, close_dialog: false, terminate_process: true)
          else
            workspace&.cleanup
          end
          progress&.result(
            status: :error,
            title: 'IndoorGML temp GML creation failed',
            message: e.message,
            actions: [:close]
          )
        end

        def perform_check_validity(session)
          state = session.state
          state[:after_temp_export] = proc do |temp_path|
            start_val3dity_validation(session, temp_path)
          end
          start_temp_file_creation(
            session,
            output_path: session.workspace&.gml_path,
            step: :temp_file
          )
        end

        def start_temp_file_creation(session, output_path: nil, step: :temp_file)
          return unless session.active?

          progress = session.progress
          state = session.state
          indoor_model = session.indoor_model

          progress.running(step)
          progress.detail(
            step,
            percent: 0,
            phase: 'Starting GML export',
            message: 'Preparing temporary IndoorGML file'
          )
          state[:temp_file_running] = true
          exporter = IndoorGmlConverter::GmlExporter.new(
            indoor_model,
            refresh_runtime_data: false
          )
          export_options = {}
          export_options[:output_path] = output_path if output_path
          temp_path = exporter.export(**export_options)
          finish_temp_gml_export(progress, state, temp_path, step)
        rescue StandardError => e
          state[:temp_file_running] = false
          state[:completed] = true
          @validation_operation_running = false if step == :temp_file
          session.cancel(reason: :failed, close_dialog: false, terminate_process: true) if step == :temp_file
          progress&.fail(step)
          progress&.result(
            status: :error,
            title: 'IndoorGML temp GML creation failed',
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
            after_temp_export: nil,
            started: false,
            completed: false,
            cancelled: false,
            overlap_tol: IndoorGmlConverter::Val3dityRunner::STRICT_OVERLAP_TOL
          }
        end

        def finish_temp_gml_export(progress, state, temp_path, step)
          state[:temp_file_running] = false
          progress.complete(step)
          return if state[:close_after_temp] || state[:cancelled]

          state[:after_temp_export]&.call(temp_path)
        end

        def start_val3dity_validation(session, temp_path)
          return unless session.active?

          progress = session.progress
          state = session.state
          indoor_model = session.indoor_model
          validator = IndoorGmlConverter::Val3dityRunner.new(
            temp_path,
            overlap_tol: state[:overlap_tol],
            work_dir: session.workspace&.root_dir,
            indoor_model: indoor_model
          )

          state[:val_running] = true
          generation = session.generation
          val_session = validator.start(
            progress: progress,
            active: proc { session.active_generation?(generation) }
          ) do |result|
            next unless session.active_generation?(generation)
            next if state[:cancelled]

            state[:val_running] = false
            state[:completed] = true
            @validation_operation_running = false
            session.result_ready!
            handle_validation_result(session, result, temp_path)
          end
          session.assign_val_session(val_session)
        rescue StandardError => e
          state[:val_running] = false
          state[:completed] = true
          @validation_operation_running = false
          session.cancel(reason: :failed, close_dialog: false, terminate_process: true)
          progress&.fail(:val3dity)
          progress&.result(
            status: :error,
            title: 'IndoorGML validity check failed',
            message: e.message,
            actions: [:close]
          )
        end

        def configure_validation_close_handler(session)
          progress = session.progress
          state = session.state
          progress.on_request_close do
            if state[:temp_file_running]
              state[:close_after_temp] = true
              session.cancel(reason: :user_cancelled, close_dialog: false, terminate_process: false)
              :close
            elsif state[:val_running] && !state[:completed]
              if IndoorGmlConverter::Val3dityRunner.shutting_down?
                state[:cancelled] = true
                state[:val_running] = false
                @validation_operation_running = false
                session.cancel(reason: :user_cancelled, close_dialog: false, terminate_process: true)
                :close
              elsif UI.messagebox("Validation is still running.\nCancel validation?", MB_YESNO) == IDYES
                state[:cancelled] = true
                state[:val_running] = false
                @validation_operation_running = false
                session.cancel(reason: :user_cancelled, close_dialog: false, terminate_process: true)
                :close
              else
                :keep_open
              end
            else
              session.complete(reason: :closed)
              :close
            end
          end
        end

        def configure_validation_cancel_handler(session)
          progress = session.progress
          state = session.state
          progress.on_cancel do
            if state[:val_running] && !state[:completed]
              state[:cancelled] = true
              state[:val_running] = false
              state[:completed] = true
              @validation_operation_running = false
              session.cancel(reason: :user_cancelled, close_dialog: false, terminate_process: true)
              progress&.fail(:val3dity)
              progress&.result(
                status: :error,
                title: 'IndoorGML validation canceled',
                message: 'Validation was canceled.',
                actions: [:close]
              )
            elsif state[:temp_file_running]
              state[:cancelled] = true
              state[:temp_file_running] = false
              state[:completed] = true
              @validation_operation_running = false
              session.cancel(reason: :user_cancelled, close_dialog: false, terminate_process: false)
              progress&.fail(:temp_file)
              progress&.result(
                status: :error,
                title: 'IndoorGML temp GML creation canceled',
                message: 'Temporary GML creation was canceled.',
                actions: [:close]
              )
            end
          end
        end

        def handle_validation_result(session, result, _temp_path)
          progress = session.progress
          progress&.on_create_gml do
            next unless session.guard_report_action

            export_runtime_gml(session.indoor_model, progress)
          end
          progress&.on_open_report do
            next unless session.guard_report_action

            begin
              open_report_dialog(result.report_html_path, progress)
            rescue StandardError => e
              progress&.set_result_message("Opening report failed:\n#{e.message}")
            end
          end
          progress&.on_validation_focus_cells do |cell_ids, code, state_ids, transition_ids, row_id|
            next unless session.guard_report_action

            incoming_refs = { cells: cell_ids, states: state_ids, transitions: transition_ids }
            indoor_model = session.indoor_model
            row = if indoor_model.validation_focus_active? && !row_id.to_s.empty? && indoor_model.respond_to?(:validation_focus_row)
                    indoor_model.validation_focus_row(row_id)
                  end
            refs = row || incoming_refs
            row_cell_ids = validation_focus_cell_ids_for_refs(refs, indoor_model)
            if row_cell_ids.empty?
              next true unless indoor_model.validation_focus_active?

              next indoor_model.set_validation_focus_highlight([], code)
            end

            unless indoor_model.validation_focus_active?
              report_cell_ids = validation_report_error_focus_cell_ids(result.report, indoor_model)
              next if report_cell_ids.empty?

              next unless indoor_model.begin_validation_focus_editing(
                report_cell_ids,
                row_states: validation_report_focus_row_states(result.report, indoor_model)
              )
            end

            row ||= if !row_id.to_s.empty? && indoor_model.respond_to?(:validation_focus_row)
                    indoor_model.validation_focus_row(row_id)
                  end
            refs = row || incoming_refs
            row_cell_ids = validation_focus_cell_ids_for_refs(refs, indoor_model)
            if row_cell_ids.empty?
              next indoor_model.set_validation_focus_highlight([], row ? row[:code] : code)
            end

            indoor_model.set_validation_focus_highlight(
              row_cell_ids,
              row ? row[:code] : code,
              row_id: row_id,
              row_cells: refs[:cells],
              states: refs[:states],
              transitions: refs[:transitions]
            )
          end
          progress&.on_fix_validation_errors do
            next unless session.guard_report_action

            begin_validation_report_edit_mode(result.report, session) unless result.valid?
          end

          if result.error?
            session.cleanup_workspace
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
              message: 'Validation completed. Open the report when ready.',
              actions: [:openReport, :close]
            )
          else
            progress&.result(
              status: :failed,
              title: 'IndoorGML validation failed',
              message: 'Validation completed with errors. Open the report for details.',
              actions: [:openReport, :close]
            )
          end
        rescue StandardError => e
          session.cleanup_workspace
          progress&.result(
            status: :error,
            title: 'IndoorGML validity result handling failed',
            message: e.message,
            actions: [:close]
          )
        end

        def validation_dialog_visible?
          @validation_progress_dialog&.visible?
        rescue StandardError
          false
        end

        def validation_session_cancelled(session)
          return unless @validation_session.equal?(session)

          @validation_operation_running = false
          @validation_session = nil
          @validation_progress_dialog = nil unless session&.progress&.visible?
        rescue StandardError
          @validation_operation_running = false
        end

        def validation_session_completed(session)
          return unless @validation_session.equal?(session)

          @validation_operation_running = false
          @validation_session = nil
          @validation_progress_dialog = nil
        rescue StandardError
          @validation_operation_running = false
        end

        def open_report_dialog(path, progress = nil)
          raise "Report file was not found:\n#{path}" unless File.exist?(path)

          dialog = progress || @validation_progress_dialog || IndoorGmlConverter::ExportProgressDialog.new
          @validation_progress_dialog = dialog
          dialog.show_report(path)
        end

        def begin_validation_report_edit_mode(report, session)
          return false unless session.guard_report_action

          indoor_model = session.indoor_model
          return false if indoor_model.validation_focus_active?

          cell_ids = validation_report_error_focus_cell_ids(report, indoor_model)
          return false if cell_ids.empty?

          indoor_model.begin_validation_focus_editing(
            cell_ids,
            row_states: validation_report_focus_row_states(report, indoor_model)
          )
        rescue StandardError => e
          Logger.puts "[IndoorGML] Validation report edit mode failed: #{e.class}: #{e.message}"
          false
        end

        def validation_report_error_focus_cell_ids(report, indoor_model = IndoorModel.current)
          IndoorGmlConverter::ValidationFocusReportMapper.error_focus_cell_ids(report, indoor_model)
        end

        def validation_report_error_refs(report)
          IndoorGmlConverter::Val3dityReportSchema.final_error_refs(report || {})
        end

        def validation_report_focus_row_states(report, indoor_model = IndoorModel.current)
          IndoorGmlConverter::ValidationFocusReportMapper.focus_row_states(report, indoor_model)
        end

        def validation_focus_cell_ids_for_refs(refs, indoor_model = IndoorModel.current)
          IndoorGmlConverter::ValidationFocusReportMapper.cell_ids_for_refs(refs, indoor_model)
        end

        def validation_cell_ref_ids(value)
          safe = validation_safe_id(value)
          return [] if safe.empty?

          if safe.start_with?('solid_cell_')
            [safe.sub(/\Asolid_/, '')]
          elsif safe.start_with?('cell_')
            [safe]
          else
            ["cell_#{safe}"]
          end
        end

        def validation_cell_gml_id(cell_space)
          validation_cell_gml_ids(cell_space).first
        end

        def validation_cell_gml_ids(cell_space)
          validation_prefixed_gml_ids('cell', cell_space&.id)
        end

        def validation_state_gml_id(state)
          validation_state_gml_ids(state).first
        end

        def validation_state_gml_ids(state)
          validation_prefixed_gml_ids('state', state&.id)
        end

        def validation_transition_gml_id(transition)
          validation_transition_gml_ids(transition).first
        end

        def validation_transition_gml_ids(transition)
          validation_prefixed_gml_ids('transition', transition&.id)
        end

        def validation_prefixed_gml_ids(prefix, value)
          safe = validation_safe_id(value)
          return [] if safe.empty?

          ids = ["#{prefix}_#{safe}"]
          ids << safe if safe.start_with?("#{prefix}_")
          ids.uniq
        end

        def validation_safe_id(value)
          value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
        end
      end
    end
  end
end
