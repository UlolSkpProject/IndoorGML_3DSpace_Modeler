# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module EditorControl
          def begin_editing
            @editor_session.begin_editing()
          end

          def finish_editing
            @finishing_editing = true
            normalize_primal_children_for_finish()
            @editor_session.finish()
          ensure
            @finishing_editing = false
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

          def set_overlay_min_radius_pixels(radius_pixels)
            radius_pixels = radius_pixels.to_f
            return false unless radius_pixels.positive?

            set_overlay_radius_pixel_range(radius_pixels, @overlay_max_radius_pixels)
          end

          def set_overlay_radius_pixel_range(min_radius_pixels, max_radius_pixels)
            begin
              min_radius_pixels = min_radius_pixels.to_f
              max_radius_pixels = max_radius_pixels.to_f
              return false unless min_radius_pixels.positive? && max_radius_pixels.positive?

              min_radius_pixels, max_radius_pixels = [min_radius_pixels, max_radius_pixels].sort
              @overlay_min_radius_pixels = min_radius_pixels
              @overlay_max_radius_pixels = max_radius_pixels
              Sketchup.active_model().active_view().invalidate() if Sketchup.active_model&.active_view
              true
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Overlay radius range update failed: #{e.class}: #{e.message}"
              false
            end
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

          def recover_unlocked_primal_after_transaction(model)
            @editor_session.recover_unlocked_primal_after_transaction(model)
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
              cell_spaces = selected_cell_spaces
              cell_spaces = [@editor_session.editing_cell_space].compact if cell_spaces.empty?
              cell_spaces = cell_spaces.select { |cell_space| cell_space&.valid? }
              if cell_spaces.empty?
                solid_snapshot = selected_solid_groups_snapshot
                return solid_snapshot if solid_snapshot

                return empty_edit_mode_snapshot
              end
              return selected_cell_spaces_snapshot(cell_spaces) if cell_spaces.length > 1

              cell_space = cell_spaces.first
              group = cell_space.sketchup_group
              {
                mode: 'cell_space',
                feature: 'CellSpace',
                id: cell_space.id,
                name: group&.name.to_s,
                cell_type: CellSpaceType.label(cell_space.cell_type),
                category_code: cell_space.category_code,
                classification: CellSpaceCategory.selection_value(cell_space.cell_type, cell_space.category_code),
                classification_locked: cell_space_type_change_locked_by_rm_helper?([cell_space]),
                transition_count: cell_space.duality_state&.transition_ids&.length.to_i,
                cell_geometry_editing: @editor_session.cell_space_geometry_editing?
              }
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Edit mode selection snapshot failed: #{e.class}: #{e.message}"
              nil
            end
          end

          def convert_selected_solid_groups_to_cell_spaces(selection_value)
            begin
              cell_type, category_code = CellSpaceCategory.parse_selection_value(selection_value)
              groups = selected_solid_groups
              return false if groups.empty?

              model = Sketchup.active_model
              operation_started = false
              converted_count = 0
              errors = []
              model.start_operation('Convert Selected Solid Groups to CellSpaces', true)
              operation_started = true
              scheduled = run_batched(
                groups,
                message: 'Converting CellSpaces...',
                batch_size: 20,
                complete: proc do
                  model.commit_operation
                  operation_started = false
                  @editor_session.selection_changed()
                  Sketchup.active_model.active_view.invalidate if Sketchup.active_model&.active_view
                  UI.messagebox(cell_space_conversion_result_message(converted_count, errors))
                end,
                failure: proc do |error|
                  model.abort_operation if operation_started
                  operation_started = false
                  IndoorCore::Logger.puts "[IndoorGML] Selected solid group conversion failed: #{error.class}: #{error.message}"
                  UI.messagebox("CellSpace conversion failed:\n#{error.message}")
                end
              ) do |group, _index|
                begin
                  convert_single_group_to_cell_space(group, cell_type, category_code)
                  converted_count += 1
                rescue StandardError => e
                  IndoorCore::Logger.puts "[IndoorGML] Selected solid group conversion failed: #{e.class}: #{e.message}"
                  errors << { group: cell_space_conversion_group_label(group), reason: e.message }
                end
              end
              unless scheduled
                model.abort_operation if operation_started
                operation_started = false
                return false
              end
              true
            rescue StandardError => e
              model.abort_operation if operation_started
              IndoorCore::Logger.puts "[IndoorGML] Selected solid group conversion failed: #{e.class}: #{e.message}"
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

          def apply_indoor_lock_policy
            @editor_session.apply_lock_policy()
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

          def selected_cell_spaces_snapshot(cell_spaces)
            {
              mode: 'cell_spaces',
              cell_space_count: cell_spaces.length,
              classification: common_cell_space_classification(cell_spaces),
              classification_locked: cell_space_type_change_locked_by_rm_helper?(cell_spaces)
            }
          end

          def empty_edit_mode_snapshot
            {
              mode: 'empty',
              cell_type_counts: cell_type_counts_snapshot,
              state_count: @states.count { |state| state&.valid? },
              total_transition_count: @transitions.count { |transition| transition&.valid? }
            }
          end

          def cell_type_counts_snapshot
            CellSpaceType::LABELS.map do |type, label|
              {
                label: label,
                count: @cell_spaces.count { |cell_space| cell_space&.valid? && cell_space.cell_type == type }
              }
            end
          end

          def common_cell_space_classification(cell_spaces)
            classifications = cell_spaces.map do |cell_space|
              CellSpaceCategory.selection_value(cell_space.cell_type, cell_space.category_code)
            end.uniq

            classifications.length == 1 ? classifications.first : nil
          end

          def selected_solid_groups_snapshot
            groups = selected_solid_groups
            return nil if groups.empty?

            {
              mode: 'solid_groups',
              solid_group_count: groups.length,
              classification: solid_groups_classification(groups),
              classification_locked: solid_groups_classification_locked_by_rm_helper?(groups)
            }
          end

          def solid_groups_classification(groups)
            rm_helper_classification = common_rm_helper_classification(groups)
            return rm_helper_classification unless rm_helper_classification.nil?

            CellSpaceCategory.selection_value(
              CellSpaceType::GENERAL,
              CellSpaceCategory.default_for(CellSpaceType::GENERAL)[:code]
            )
          end

          def solid_groups_classification_locked_by_rm_helper?(groups)
            !common_rm_helper_classification(groups).nil?
          end

          def common_rm_helper_classification(groups)
            targets = groups.map { |group| IndoorCore.rm_helper_cell_space_type_and_category(group) }
            return nil if targets.empty? || targets.any?(&:nil?)

            classifications = targets.map do |target|
              CellSpaceCategory.selection_value(target[0], target[1])
            end.uniq

            classifications.length == 1 ? classifications.first : nil
          end

          def cell_space_conversion_group_label(group)
            name = group.respond_to?(:name) ? group.name.to_s.strip : ''
            id = group.respond_to?(:entityID) ? group.entityID : nil
            return "#{name} (entity #{id})" unless name.empty? || id.nil?
            return name unless name.empty?
            return "entity #{id}" unless id.nil?

            'unknown group'
          end

          def cell_space_conversion_result_message(converted_count, errors)
            message = +"Succeed : #{converted_count}\nFailed : #{errors.length}"
            return message if errors.empty?

            grouped_errors = errors.group_by { |error| cell_space_conversion_reason_label(error[:reason]) }
            grouped_errors.each do |reason, entries|
              message << "\n- #{reason}"
              entries.each do |entry|
                message << "\n  #{entry[:group]}"
              end
            end
            message
          end

          def cell_space_conversion_reason_label(reason)
            return 'SolidGroup내 분리된 형상' if reason.to_s.include?('Disconnected solid shells detected')

            reason.to_s.empty? ? '알 수 없는 실패 원인' : reason.to_s
          end

          def cell_space_type_change_locked_by_rm_helper?(cell_spaces)
            return false if cell_spaces.empty?

            cell_spaces.all? do |cell_space|
              target = IndoorCore.rm_helper_cell_space_type_and_category(cell_space.sketchup_group)
              target && cell_space.cell_type == target[0] && cell_space.category_code == target[1]
            end
          end

          def selected_solid_groups
            selection = Sketchup.active_model&.selection
            return [] unless selection
            entities = selection.to_a
            return [] if entities.empty?

            groups = entities.grep(Sketchup::Group)
            return [] unless groups.length == entities.length

            solid_groups = groups.select do |group|
              group&.valid? &&
                group.respond_to?(:manifold?) &&
                group.manifold? &&
                find_cell_space_for_entity(group).nil?
            end
            solid_groups.length == groups.length ? solid_groups : []
          end
        end
      end
    end
  end
end
