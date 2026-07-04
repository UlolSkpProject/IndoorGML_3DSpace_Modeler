# frozen_string_literal: true

require 'fileutils'
require_relative '../../export/validation_session'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ExportCommands
        def validation_operation_running?
          @validation_session&.running? == true || @validation_operation_running == true
        end

        def export_gml
          return if validation_operation_running?

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
          return if validation_operation_running?

          if validation_dialog_visible?
            @validation_progress_dialog.bring_to_front
            return
          end

          captured_model = Sketchup.active_model
          captured_indoor_model = IndoorModel.for(captured_model)
          captured_indoor_model.finish_editing if captured_indoor_model.editing?
          @validation_operation_running = true
          progress = IndoorGmlConverter::ExportProgressDialog.new
          @validation_progress_dialog = progress
          state = validation_close_state
          session = IndoorGmlConverter::ValidationSession.new(
            model: captured_model,
            indoor_model: captured_indoor_model,
            progress: progress,
            state: state,
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
          @validation_session&.cancel(reason: :failed, close_dialog: false, terminate_process: true)
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
          start_temp_file_creation(session, step: :temp_file)
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

        def handle_validation_result(session, result, temp_path)
          progress = session.progress
          progress&.on_create_gml do
            next unless session.guard_report_action

            create_gml_from_temp(temp_path, progress)
          end
          progress&.on_open_report do
            next unless session.guard_report_action

            begin
              open_report_dialog(result.report_html_path, progress)
            rescue StandardError => e
              progress&.set_result_message("Opening report failed:\n#{e.message}")
            end
          end
          progress&.on_validation_focus_cells do |cell_ids, code, state_ids, transition_ids|
            next unless session.guard_report_action

            refs = { cells: cell_ids, states: state_ids, transitions: transition_ids }
            indoor_model = session.indoor_model
            focus_cell_ids = validation_focus_cell_ids_for_refs(refs, indoor_model)
            if focus_cell_ids.empty?
              indoor_model.set_validation_focus_highlight([], code) if indoor_model.validation_focus_active?
            else
              indoor_model.begin_validation_focus_editing(focus_cell_ids) unless indoor_model.validation_focus_active?
              indoor_model.set_validation_focus_highlight(focus_cell_ids, code)
            end
          end
          progress&.on_fix_validation_errors do
            next unless session.guard_report_action

            begin_validation_report_edit_mode(result.report, session) unless result.valid?
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

          indoor_model.begin_validation_focus_editing(cell_ids)
        rescue StandardError => e
          Logger.puts "[IndoorGML] Validation report edit mode failed: #{e.class}: #{e.message}"
          false
        end

        def validation_report_error_focus_cell_ids(report, indoor_model = IndoorModel.current)
          refs = validation_report_error_refs(report)
          validation_focus_cell_ids_for_refs(refs, indoor_model)
        end

        def validation_report_error_refs(report)
          errors = []
          Array(report && report['dataset_errors']).each { |error| errors << error }
          Array(report && report['features']).each do |feature|
            Array(feature['errors']).each { |error| errors << error }
            Array(feature['primitives']).each do |primitive|
              Array(primitive['errors']).each { |error| errors << error }
            end
          end

          refs = { cells: [], states: [], transitions: [] }
          errors.each do |error|
            text = validation_error_text(error)
            refs[:cells].concat(text.scan(/cell_[A-Za-z0-9_.-]+/))
            refs[:states].concat(text.scan(/state_[A-Za-z0-9_.-]+/))
            refs[:transitions].concat(text.scan(/transition_[A-Za-z0-9_.-]+/))
          end
          refs.each_value(&:uniq!)
          refs
        end

        def validation_focus_cell_ids_for_refs(refs, indoor_model = IndoorModel.current)
          model = indoor_model
          cell_ids = Array(refs[:cells]).dup

          model.states.each do |state|
            next unless state&.valid?
            next unless Array(refs[:states]).include?(validation_state_gml_id(state))

            cell = state.duality_cell
            cell_ids << validation_cell_gml_id(cell) if cell&.valid?
          end

          model.transitions.each do |transition|
            next unless transition&.valid?
            next unless Array(refs[:transitions]).include?(validation_transition_gml_id(transition))

            [transition.state1&.duality_cell, transition.state2&.duality_cell].each do |cell|
              cell_ids << validation_cell_gml_id(cell) if cell&.valid?
            end
          end

          cell_ids.compact.uniq
        end

        def validation_error_text(value)
          case value
          when Hash
            value.values.map { |child| validation_error_text(child) }.join(' ')
          when Array
            value.map { |child| validation_error_text(child) }.join(' ')
          else
            value.to_s
          end
        end

        def validation_cell_gml_id(cell_space)
          return nil unless cell_space

          "cell_#{validation_safe_id(cell_space.id)}"
        end

        def validation_state_gml_id(state)
          "state_#{validation_safe_id(state.id)}"
        end

        def validation_transition_gml_id(transition)
          "transition_#{validation_safe_id(transition.id)}"
        end

        def validation_safe_id(value)
          value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
        end
      end
    end
  end
end
