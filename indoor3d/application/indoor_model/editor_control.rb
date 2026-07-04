# frozen_string_literal: true

require 'json'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module EditorControl
          def begin_editing
            @editor_session.begin_editing()
          end

          def begin_validation_focus_editing(cell_gml_ids)
            @editor_session.begin_validation_focus_editing(cell_gml_ids)
          end

          def set_validation_focus_highlight(cell_gml_ids, code = nil)
            @editor_session.set_validation_focus_highlight(cell_gml_ids, code)
          end

          def recheck_validation_focus_errors
            focus = @editor_session.validation_focus_elements
            if focus[:cell_spaces].empty?
              UI.messagebox('재검사할 오류 CellSpace가 없습니다.')
              return nil
            end

            progress = IndoorGmlConverter::ExportProgressDialog.active || IndoorGmlConverter::ExportProgressDialog.new
            state = { session: nil, completed: false }
            progress.on_create_gml do
              UI.messagebox('오류 요소 재검사 report에서는 GML export를 사용할 수 없습니다.')
            end
            progress.on_cancel do
              state[:session]&.terminate
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
              state[:session]&.terminate unless state[:completed]
              :close
            end
            progress.on_ready do
              next if state[:started]

              state[:started] = true
              start_validation_focus_recheck(progress, state, focus)
            end
            progress.show
            focus
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Validation focus recheck failed: #{e.class}: #{e.message}"
            UI.messagebox("오류 요소 재검사 실패:\n#{e.message}")
            nil
          end

          def finish_editing
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

          def convert_selected_solid_groups_to_cell_spaces(selection_value)
            begin
              cell_type, category_code = CellSpaceCategory.parse_selection_value(selection_value)
              jobs = selected_cell_space_conversion_jobs
              return false if jobs.empty?

              model = Sketchup.active_model
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
            cell_type, category_code = CellSpaceCategory.parse_selection_value(selection_value)
            set_selected_cell_space_type(CellSpaceType.label(cell_type), category_code)
          end

          def set_selected_cell_space_navigation_semantics(navigation_class, navigation_function, navigation_usage)
            begin
              cell_space = selected_cell_space
              cell_space = @editor_session.editing_cell_space if cell_space.nil?
              return false unless cell_space&.valid?
              return false unless cell_space.navigable?

              model = Sketchup.active_model()
              operation_started = false
              model.start_operation('Change CellSpace Navigation Semantics', true)
              operation_started = true
              sync do
                cell_space.set_navigation_semantics(
                  navigation_class: navigation_class,
                  navigation_function: navigation_function,
                  navigation_usage: navigation_usage
                )
                write_cell_space_attributes(cell_space)
              end
              model.commit_operation()
              remember_cell_space_change_snapshot(cell_space.sketchup_group)
              @editor_session.selection_changed()
              true
            rescue StandardError => e
              model.abort_operation() if operation_started
              IndoorCore::Logger.puts "[IndoorGML] CellSpace navigation semantics update failed: #{e.class}: #{e.message}"
              false
            end
          end

          def set_selected_cell_space_storey(storey)
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

          private

          def start_validation_focus_recheck(progress, state, focus)
            report_name = validation_focus_recheck_report_name
            output_path = File.join(IndoorGmlConverter::GmlExporter.output_root, "#{report_name}.gml")

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
              report_name: report_name,
              indoor_model: self
            )
            state[:session] = runner.start(progress: progress) do |result|
              state[:completed] = true
              handle_validation_focus_recheck_result(progress, result)
            end
          rescue StandardError => e
            state[:completed] = true
            progress.fail(:temp_file)
            progress.result(
              status: :error,
              title: '오류 요소 재검사 실패',
              message: e.message,
              actions: [:close]
            )
          end

          def handle_validation_focus_recheck_result(progress, result)
            if result.error?
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
            progress.result(
              status: :error,
              title: '오류 요소 재검사 결과 처리 실패',
              message: e.message,
              actions: [:close]
            )
          end

          def validation_focus_recheck_report_name
            "fix_recheck_#{Time.now.strftime('%Y%m%d_%H%M%S')}"
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
            StoreyFilterOptionsBuilder.build(@cell_spaces)
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
