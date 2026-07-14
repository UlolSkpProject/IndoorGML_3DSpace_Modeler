# frozen_string_literal: true

require 'fileutils'
require 'json'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module EditorControl
          def begin_editing
            @editor_session.begin_editing()
          end

          def begin_validation_focus_editing(cell_gml_ids, row_states: nil)
            @editor_session.begin_validation_focus_editing(cell_gml_ids, row_states: row_states)
          end

          def set_validation_focus_highlight(cell_gml_ids, code = nil, row_id: nil, row_cells: nil, states: nil, transitions: nil)
            @editor_session.set_validation_focus_highlight(
              cell_gml_ids,
              code,
              row_id: row_id,
              row_cells: row_cells,
              states: states,
              transitions: transitions
            )
          end

          def recheck_validation_focus_errors
            if validation_focus_recheck_running?
              UI.messagebox('오류 요소 재검사가 이미 실행 중입니다.')
              return nil
            end

            focus = @editor_session.validation_focus_elements
            if focus[:cell_spaces].empty?
              UI.messagebox('재검사할 오류 CellSpace가 없습니다.')
              return nil
            end

            state = {
              session: nil,
              completed: false,
              workspace: nil,
              workspace_cleaned: false
            }
            begin_validation_focus_recheck(state)
            state[:workspace] = IndoorGmlConverter::ValidationRunWorkspace.create(
              base_dir: IndoorGmlConverter::GmlExporter.output_root
            )
            @editor_session.set_validation_focus_highlight([], '')
            progress = IndoorGmlConverter::ExportProgressDialog.active || IndoorGmlConverter::ExportProgressDialog.new
            progress.on_create_gml do
              export_full_gml_from_validation_focus_recheck_report(progress)
            end
            progress.on_cancel do
              terminate_validation_focus_recheck(state)
              state[:completed] = true
              progress.fail(:val3dity)
              progress.result(
                status: :error,
                title: '오류 요소 재검사 취소',
                message: '재검사가 취소되었습니다.',
                actions: [:close]
              )
            end
            progress.on_request_close do
              unless state[:completed]
                terminate_validation_focus_recheck(state)
                state[:completed] = true
              end
              cleanup_validation_focus_recheck_workspace(state) if state[:completed]
              :close
            end
            progress.on_ready do
              next if state[:completed]
              next if state[:started]

              state[:started] = true
              start_validation_focus_recheck(progress, state, focus)
            end
            progress.show
            focus
          rescue StandardError => e
            if defined?(state) && state
              cleanup_validation_focus_recheck_workspace(state)
            else
              finish_validation_focus_recheck(nil)
            end
            IndoorCore::Logger.puts "[IndoorGML] Validation focus recheck failed: #{e.class}: #{e.message}"
            UI.messagebox("오류 요소 재검사 실패:\n#{e.message}")
            nil
          end

          def finish_editing
            return false if validation_focus_recheck_running?

            with_guard_flag(:@finishing_editing) do
              @editor_session.restore_validation_focus_visibility if @editor_session.validation_focus_active?
              finished = @editor_session.finish()
              if finished
                normalize_primal_children_for_finish()
              #   refresh_runtime_data()
              end
              finished
            end
          end

          def request_finish_editing
            return false if validation_focus_recheck_running?

            IndoorCore::Logger.puts '[IndoorGML] EditModeDialog#RequestfinishEditing'
            result = UI.messagebox("CellSpace 편집을 종료하시겠습니까?", MB_YESNO)
            return false unless result == IDYES

            finish_editing
            return true
          end

          def editing?
            @editor_session.editing?()
          end

          def dual_overlay_visible?
            @editor_session.dual_overlay_visible?()
          end

          def toggle_dual_overlay_visible
            @editor_session.toggle_dual_overlay_visible()
          end

          def geometry_visible?
            @editor_session.geometry_visible?()
          end

          def toggle_geometry_visible
            @editor_session.toggle_geometry_visible()
          end

          def progress_active?
            @editor_session.progress_active?()
          end

          def progress_current
            @editor_session.progress_current()
          end

          def progress_total
            @editor_session.progress_total()
          end

          def progress_message
            @editor_session.progress_message()
          end

          def cell_space_geometry_editing?
            @editor_session.cell_space_geometry_editing?()
          end

          def validation_focus_active?
            @editor_session.validation_focus_active?
          end

          def validation_focus_recheck_running?
            @validation_focus_recheck_running == true
          end

          def validation_focus_cell_space?(cell_space)
            @editor_session.validation_focus_cell_space?(cell_space)
          end

          def validation_focus_state?(state)
            @editor_session.validation_focus_state?(state)
          end

          def dual_overlay_state_visible?(state)
            @editor_session.dual_overlay_state_visible?(state)
          end

          def dual_overlay_transition_visible?(transition)
            @editor_session.dual_overlay_transition_visible?(transition)
          end

          def validation_focus_highlight_cell_spaces
            @editor_session.validation_focus_highlight_cell_spaces
          end

          def validation_focus_highlight_code
            @editor_session.validation_focus_highlight_code
          end

          def validation_focus_highlight_active?
            @editor_session.validation_focus_highlight_active?
          end

          def add_validation_focus_highlight_cell(cell_space)
            payload = @editor_session.add_validation_focus_highlight_cell(cell_space)
            return nil unless payload

            puts "[IndoorGML] validation focus ref-cells: #{Array(payload[:cells]).inspect}"
            update_validation_focus_report_row(payload)
          end

          def remove_validation_focus_highlight_cell(cell_space)
            Array(@editor_session.remove_validation_focus_highlight_cell(cell_space)).each do |payload|
              update_validation_focus_report_row(payload)
            end
          end

          def invalidate_overlay_transition_points
            @editor_session.invalidate_overlay_transition_points
          end

          def edit_mode_visibility_filter_snapshot
            {
              storey_options: edit_mode_storey_filter_options,
              selected_storeys: @editor_session.visible_storeys,
              cell_type_options: edit_mode_cell_type_filter_options,
              selected_cell_types: @editor_session.visible_cell_type_labels
            }
          end

          def set_edit_mode_visibility_filter(storeys, cell_types)
            @editor_session.set_visibility_filter(
              storeys: parse_visibility_filter_values(storeys),
              cell_types: parse_visibility_filter_values(cell_types)
            )
          end

          def run_batched(items, message:, batch_size: 20, complete: nil, failure: nil, &block)
            @editor_session.run_batched(
              items,
              message: message,
              batch_size: batch_size,
              complete: complete,
              failure: failure,
              &block
            )
          end

          def clear_all_indoor_gml_elements
            model = Sketchup.active_model()
            confirmed = UI.messagebox(
              'Clear all IndoorGML elements?',
              MB_YESNO
            )
            return false unless confirmed == IDYES

            model.start_operation('Clear All IndoorGML Elements', true)
            begin
              @editor_session.finish() if editing?
              clear_indoor_gml_groups()
              reset_runtime_collections()
              model.active_view.invalidate if model&.active_view
              model.commit_operation
              true
            rescue StandardError => e
              model.abort_operation
              IndoorCore::Logger.puts "[IndoorGML] Clear all failed: #{e.class}: #{e.message}"
              false
            end
          end

          def active_path_changed(model)
            @editor_session.active_path_changed(model)
          end

          def cleanup_before_quit
            @editor_session.cleanup_before_quit()
          end

          def attach_edit_selection_observer(model = Sketchup.active_model)
            begin
              return unless model&.selection
              return if @selection_observed_model_id == model.object_id

              model.selection.add_observer(@selection_observer)
              @selection_observed_model_id = model.object_id
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Selection observer attach failed: #{e.class}: #{e.message}"
            end
          end

          def detach_edit_selection_observer(model = Sketchup.active_model)
            begin
              return unless model&.selection
              return unless @selection_observed_model_id == model.object_id

              model.selection.remove_observer(@selection_observer)
              @selection_observed_model_id = nil
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Selection observer detach failed: #{e.class}: #{e.message}"
            end
          end

          def selection_changed
            @editor_session.selection_changed()
          end

          def selected_edit_mode_snapshot
            begin
              edit_mode_selection_projection.snapshot(
                selected_cell_spaces: selected_cell_spaces,
                solid_jobs: selected_cell_space_conversion_jobs
              )
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Edit mode selection snapshot failed: #{e.class}: #{e.message}"
              nil
            end
          end

          def update_validation_focus_report_row(payload)
            return nil unless payload

            dialog = IndoorGmlConverter::ExportProgressDialog.active
            dialog&.update_validation_focus_row(
              row_id: payload[:row_id],
              cells: payload[:cells],
              states: payload[:states],
              transitions: payload[:transitions],
              label: payload[:label]
            )
            payload
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Validation focus report row update failed: #{e.class}: #{e.message}"
            nil
          end

          def convert_selected_solid_groups_to_cell_spaces(selection_value)
            return false if validation_focus_recheck_running?

            begin
              cell_type, category_code = CellSpaceCategory.parse_selection_value(selection_value)
              model = Sketchup.active_model
              unless prepare_cell_space_creation_active_context(model)
                raise 'Failed to prepare active context for CellSpace conversion'
              end
              jobs = selected_cell_space_conversion_jobs
              return false if jobs.empty?

              original_active_path = ActivePathController.new(model, logger: IndoorCore::Logger).snapshot
              result = convert_cell_space_jobs_bulk(
                jobs,
                fallback_target: [cell_type, category_code],
                original_active_path: original_active_path,
                preserve_source: method(:inside_primal_group?),
                operation_name: 'Convert Selected Solid Groups to CellSpaces',
                activate_root_context: true
              )
              @editor_session.selection_changed()
              Sketchup.active_model.active_view.invalidate if Sketchup.active_model&.active_view
              UI.messagebox(ConversionMessageFormatter.result_message(result.converted_count, result.errors))
              true
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Selected solid group conversion failed: #{e.class}: #{e.message}"
              UI.messagebox("CellSpace conversion failed:\n#{e.message}")
              false
            end
          end

          def set_selected_cell_space_type(cell_type_label, category_code = nil)
            return false if validation_focus_recheck_running?

            begin
              cell_spaces = selected_cell_spaces
              cell_spaces = [@editor_session.editing_cell_space].compact if cell_spaces.empty?
              cell_spaces = cell_spaces.select { |cell_space| cell_space&.valid? }
              return false if cell_spaces.empty?

              model = Sketchup.active_model()
              operation_started = false
              model.start_operation('Change CellSpace Type and Category', true)
              operation_started = true
              cell_type = CellSpaceType.from_label(cell_type_label)
              category_code = nil unless CellSpaceCategory.valid_for_type?(cell_type, category_code)
              cell_spaces.each do |cell_space|
                change_cell_space_type(cell_space.sketchup_group, cell_type, category_code)
              end
              model.commit_operation()
              @editor_session.refresh_visibility_filter
              @editor_session.selection_changed()
              model.active_view().invalidate() if model&.active_view
              true
            rescue StandardError => e
              model.abort_operation() if operation_started
              IndoorCore::Logger.puts "[IndoorGML] Selected CellSpace type update failed: #{e.class}: #{e.message}"
              false
            end
          end

          def set_selected_cell_space_classification(selection_value)
            return false if validation_focus_recheck_running?

            cell_type, category_code = CellSpaceCategory.parse_selection_value(selection_value)
            set_selected_cell_space_type(CellSpaceType.label(cell_type), category_code)
          end

          def set_selected_cell_space_storey(storey)
            return false if validation_focus_recheck_running?

            begin
              cell_spaces = selected_cell_spaces
              cell_spaces = [@editor_session.editing_cell_space].compact if cell_spaces.empty?
              cell_spaces = cell_spaces.select { |cell_space| cell_space&.valid? }
              return false if cell_spaces.empty?
              return false if cell_spaces.length > 1 && common_cell_space_type(cell_spaces).nil?
              normalized_storey = storey_range_allowed_for_cell_spaces(cell_spaces) ? storey : first_storey_value(storey)

              model = Sketchup.active_model()
              operation_started = false
              model.start_operation('Change CellSpace Storey', true)
              operation_started = true
              sync do
                cell_spaces.each do |cell_space|
                  cell_space.set_storey(normalized_storey)
                  write_cell_space_attributes(cell_space)
                end
              end
              model.commit_operation()
              cell_spaces.each { |cell_space| remember_cell_space_change_snapshot(cell_space.sketchup_group) }
              @editor_session.refresh_visibility_filter
              @editor_session.selection_changed()
              true
            rescue StandardError => e
              model.abort_operation() if operation_started
              IndoorCore::Logger.puts "[IndoorGML] Selected CellSpace storey update failed: #{e.class}: #{e.message}"
              false
            end
          end

          def edit_selected_cell_space_geometry
            begin
              cell_space = selected_cell_space
              return false unless cell_space&.valid?

              @editor_session.edit_cell_space_geometry(cell_space)
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Selected CellSpace geometry edit failed: #{e.class}: #{e.message}"
              false
            end
          end

          def finish_cell_space_geometry_editing
            @editor_session.finish_cell_space_geometry_editing()
          end

          def with_active_path_enforcement_suspended
            @editor_session.with_active_path_enforcement_suspended { yield }
          end

          def prepare_cell_space_creation_active_context(model = Sketchup.active_model)
            edit_context = editing? || validation_focus_active?
            ActivePathController.new(model, logger: IndoorCore::Logger).normalize_for_cell_space_creation(
              primal_group: @primal_group,
              edit_context: edit_context
            )
          end

          private

          def start_validation_focus_recheck(progress, state, focus)
            workspace = state[:workspace]
            output_path = workspace.gml_path

            progress.running(:temp_file)
            progress.detail(
              :temp_file,
              percent: 0,
              phase: '오류 요소 GML 생성',
              message: validation_focus_recheck_summary(focus),
              current: File.basename(output_path)
            )
            IndoorGmlConverter::GmlExporter.new(
              self,
              refresh_runtime_data: false,
              cell_spaces: focus[:cell_spaces],
              transitions: focus[:transitions]
            ).export(output_path: output_path)
            progress.complete(:temp_file)

            runner = IndoorGmlConverter::Val3dityRunner.new(
              output_path,
              overlap_tol: IndoorGmlConverter::Val3dityRunner::STRICT_OVERLAP_TOL,
              work_dir: workspace.root_dir,
              indoor_model: self
            )
            state[:session] = runner.start(progress: progress) do |result|
              state[:completed] = true
              finish_validation_focus_recheck(state)
              handle_validation_focus_recheck_result(progress, state, result)
            end
          rescue StandardError => e
            state[:completed] = true
            cleanup_validation_focus_recheck_workspace(state)
            progress.fail(:temp_file)
            progress.result(
              status: :error,
              title: '오류 요소 재검사 실패',
              message: e.message,
              actions: [:close]
            )
          end

          def export_full_gml_from_validation_focus_recheck_report(progress)
            path = UI.savepanel('Export GML', '~', 'IndoorGML Files|*.gml;||')
            if path.to_s.empty?
              progress&.set_result_message('GML export canceled.')
              return nil
            end

            path = "#{path}.gml" unless File.extname(path).downcase == '.gml'
            FileUtils.mkdir_p(File.dirname(path))
            finish_editing if editing?
            IndoorGmlConverter::GmlExporter.new(self).export(output_path: path)
            progress&.set_result_message("GML exported:\n#{path}")
            path
          rescue StandardError => e
            progress&.set_result_message("GML export failed:\n#{e.message}")
            nil
          end

          def handle_validation_focus_recheck_result(progress, state, result)
            if result.error?
              cleanup_validation_focus_recheck_workspace(state)
              progress.fail(:val3dity)
              progress.result(
                status: :error,
                title: '오류 요소 재검사 실패',
                message: result.error.message,
                actions: [:close]
              )
              return
            end

            progress.on_open_report do
              progress.show_report(result.report_html_path)
            end
            progress.result(
              status: result.valid? ? :success : :failed,
              title: result.valid? ? '오류 요소 재검사 통과' : '오류 요소 재검사 실패',
              message: result.valid? ? '선택된 오류 요소가 유효합니다.' : '선택된 오류 요소에 오류가 남아 있습니다.',
              actions: [:openReport, :close]
            )
          rescue StandardError => e
            cleanup_validation_focus_recheck_workspace(state)
            progress.result(
              status: :error,
              title: '오류 요소 재검사 결과 처리 실패',
              message: e.message,
              actions: [:close]
            )
          end

          def cleanup_validation_focus_recheck_workspace(state)
            return unless state
            return if state[:workspace_cleaned]
            unless validation_focus_recheck_process_finished?(state)
              state[:workspace_cleanup_pending] = true
              schedule_validation_focus_recheck_workspace_cleanup(state)
              return false
            end

            finalize_validation_focus_recheck_session(state)
            finish_validation_focus_recheck(state)

            workspace = state[:workspace]
            unless workspace&.respond_to?(:cleanup)
              state[:workspace_cleaned] = true
              stop_validation_focus_recheck_cleanup_timer(state)
              return true
            end

            cleaned = workspace.cleanup
            if cleaned
              state[:workspace_cleaned] = true
              stop_validation_focus_recheck_cleanup_timer(state)
            end
            cleaned
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Validation focus recheck workspace cleanup failed: #{e.class}: #{e.message}"
            false
          end

          def terminate_validation_focus_recheck(state)
            session = state[:session]
            unless validation_focus_recheck_process_finished?(state)
              terminated = session&.respond_to?(:terminate) && session.terminate(wait_ms: IndoorGmlConverter::Val3dityRunner::TERMINATE_WAIT_MS)
              state[:workspace_cleanup_pending] = true unless terminated && validation_focus_recheck_process_finished?(state)
            end
            cleanup_validation_focus_recheck_workspace(state)
          rescue StandardError => e
            state[:workspace_cleanup_pending] = true
            schedule_validation_focus_recheck_workspace_cleanup(state)
            IndoorCore::Logger.puts "[IndoorGML] Validation focus recheck terminate failed: #{e.class}: #{e.message}"
            false
          end

          def validation_focus_recheck_process_finished?(state)
            session = state[:session]
            return true unless session&.respond_to?(:finished?)

            session.finished?
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Validation focus recheck process status failed: #{e.class}: #{e.message}"
            false
          end

          def schedule_validation_focus_recheck_workspace_cleanup(state)
            return if state[:workspace_cleanup_timer_scheduled]
            return unless defined?(UI) && UI.respond_to?(:start_timer)

            state[:workspace_cleanup_timer_scheduled] = true
            state[:workspace_cleanup_timer_id] = UI.start_timer(0.2, true) do
              if state[:workspace_cleaned]
                stop_validation_focus_recheck_cleanup_timer(state)
                next false
              end

              if validation_focus_recheck_process_finished?(state)
                state[:workspace_cleanup_timer_scheduled] = false
                cleaned = cleanup_validation_focus_recheck_workspace(state)
                stop_validation_focus_recheck_cleanup_timer(state) if cleaned
                next !cleaned
              end

              true
            rescue StandardError => e
              state[:workspace_cleanup_timer_scheduled] = false
              stop_validation_focus_recheck_cleanup_timer(state)
              IndoorCore::Logger.puts "[IndoorGML] Validation focus recheck pending cleanup failed: #{e.class}: #{e.message}"
              false
            end
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Validation focus recheck cleanup timer failed: #{e.class}: #{e.message}"
          end

          def stop_validation_focus_recheck_cleanup_timer(state)
            timer_id = state.delete(:workspace_cleanup_timer_id)
            state[:workspace_cleanup_timer_scheduled] = false
            return if timer_id.nil?
            return unless defined?(UI) && UI.respond_to?(:stop_timer)

            UI.stop_timer(timer_id)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Validation focus recheck cleanup timer stop failed: #{e.class}: #{e.message}"
          end

          def finalize_validation_focus_recheck_session(state)
            session = state[:session]
            return unless session

            session.join_reader if session.respond_to?(:join_reader)
            session.close if session.respond_to?(:close)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Validation focus recheck session finalize failed: #{e.class}: #{e.message}"
          end

          def begin_validation_focus_recheck(state)
            @validation_focus_recheck_state = state
            @validation_focus_recheck_running = true
            @editor_session.selection_changed if @editor_session.respond_to?(:selection_changed)
            true
          end

          def finish_validation_focus_recheck(state)
            return false unless validation_focus_recheck_running?
            return false if state && @validation_focus_recheck_state && !@validation_focus_recheck_state.equal?(state)

            @validation_focus_recheck_running = false
            @validation_focus_recheck_state = nil
            state[:operation_finished] = true if state
            @editor_session.selection_changed if @editor_session.respond_to?(:selection_changed)
            true
          end

          def validation_focus_recheck_summary(focus)
            "CellSpace #{focus[:cell_spaces].length}개, State #{focus[:states].length}개, Transition #{focus[:transitions].length}개 재검사"
          end

          def apply_indoor_lock_policy
            @editor_session.apply_lock_policy()
          end

          def edit_mode_selection_projection
            EditModeSelectionProjection.new(
              cell_spaces: @cell_spaces,
              states: @states,
              transitions: @transitions,
              editor_session: @editor_session,
              visibility_filter: edit_mode_visibility_filter_snapshot
            )
          end

          def parse_visibility_filter_values(values)
            if values.is_a?(String)
              parsed = JSON.parse(values)
              return Array(parsed).map(&:to_s)
            end

            Array(values).map(&:to_s)
          rescue StandardError
            []
          end

          def edit_mode_storey_filter_options
            StoreyFilter.options_for(@cell_spaces)
          end

          def edit_mode_cell_type_filter_options
            CellSpaceType::SELECTABLE_TYPES.map do |cell_type|
              label = CellSpaceType.label(cell_type)
              { value: label, label: label }
            end
          end

          def selected_cell_space
            selected_cell_spaces.first
          end

          def selected_cell_spaces
            selection = Sketchup.active_model&.selection
            return [] unless selection

            selection.each_with_object([]) do |entity, result|
              cell_space = find_cell_space_for_entity(entity)
              result << cell_space if cell_space&.valid?
            end
          end

          def common_cell_space_type(cell_spaces)
            types = cell_spaces.map(&:cell_type).uniq
            types.length == 1 ? types.first : nil
          end

          def storey_range_allowed_for_cell_spaces(cell_spaces)
            cell_spaces = Array(cell_spaces).select { |cell_space| cell_space&.valid? }
            return false if cell_spaces.empty?

            cell_spaces.all? do |cell_space|
              cell_space.cell_type == CellSpaceType::TRANSITION &&
                %w[Stair Elevator].include?(cell_space.category_code.to_s)
            end
          end

          def first_storey_value(value)
            value.to_s.split('~', 2).first
          end

          def selected_cell_space_conversion_jobs
            selection = Sketchup.active_model&.selection
            return [] unless selection

            CellSpaceConversionJobBuilder.new(entities: selection.to_a).build
          end

        end
      end
    end
  end
end
