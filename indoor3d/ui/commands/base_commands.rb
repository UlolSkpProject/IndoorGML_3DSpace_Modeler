# frozen_string_literal: true

require_relative '../ui_feedback'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module BaseCommands
        def refresh_runtime_data
          indoor_model = IndoorModel.current
          scheduled = indoor_model.run_batched(
            [:refresh_runtime_data],
            message: 'Refreshing...',
            batch_size: 1,
            complete: proc do
              UiFeedback.defer_modal('IndoorGML runtime data refreshed.')
            end,
            failure: proc do |error|
              UiFeedback.defer_modal("Runtime refresh failed:\n#{error.message}")
            end
          ) do
            indoor_model.refresh_runtime_data
          end

          indoor_model.refresh_runtime_data unless scheduled
        rescue StandardError => e
          UiFeedback.defer_modal("Runtime refresh failed:\n#{e.message}")
        end

        def selected_indoor_gml_entities
          Sketchup.active_model.selection.to_a.select do |entity|
            entity&.valid? && indoor_feature(entity).to_s.length.positive?
          end
        end

        def indoor_feature(entity)
          entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
        rescue StandardError
          nil
        end

        def cell_space_type_change_available?(groups)
          cell_space_groups = Array(groups).select { |group| indoor_feature(group) == 'CellSpace' }
          return false if cell_space_groups.empty?

          !cell_space_groups.all? { |group| tag_cell_space_type_matches_indoor_attributes?(group) }
        end

        private

        def tag_cell_space_type_and_category(entity)
          TagCellSpaceAdapter.cell_space_type_and_category(entity)
        end

        def tag_assigned?(entity)
          TagCellSpaceAdapter.tag_assigned?(entity)
        end

        def prompt_cell_space_type_and_category(title)
          options = CellSpaceCategory.selection_options
          labels = options.map { |option| option[:label] }
          result = UI.inputbox(
            ['CellSpace'],
            [labels.first],
            [labels.join('|')],
            title
          )
          return nil unless result

          option = options.find { |candidate| candidate[:label] == result.first } || options.first
          [option[:cell_type], option[:category_code]]
        end

        def cell_space_creation_dialog_payload(title, default_storey: CellSpace::DEFAULT_STOREY)
          options = CellSpaceCategory.selection_options
          default_option = options.first

          {
            title: title,
            description: '선택한 Solid Group을 CellSpace로 변환합니다.',
            cell_space_options: options.map { |option| { value: option[:label].to_s, label: option[:label].to_s } },
            selected_cell_space: default_option[:label].to_s,
            storey: default_storey.to_s.empty? ? CellSpace::DEFAULT_STOREY : default_storey.to_s
          }
        end

        def resolve_cell_space_creation_dialog_selection(selection)
          values = selection.is_a?(Hash) ? selection : {}
          cell_space_label = values['cell_space_label'] || values[:cell_space_label]
          storey = (values['storey'] || values[:storey]).to_s.strip

          options = CellSpaceCategory.selection_options
          default_option = options.first
          option = options.find { |candidate| candidate[:label].to_s == cell_space_label.to_s } || default_option

          storey = CellSpace::DEFAULT_STOREY if storey.empty?
          [option[:cell_type], option[:category_code], storey]
        end

        def tag_cell_space_type_matches_indoor_attributes?(group)
          target = tag_cell_space_type_and_category(group)
          return false if target.nil?

          current_type = CellSpaceType.from_label(
            group.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'cell_type')
          )
          current_category_code = group.get_attribute(
            IndoorModel::ATTRIBUTE_DICTIONARY_NAME,
            'category_code'
          ).to_s
          current_type == target[0] && current_category_code == target[1]
        rescue StandardError
          false
        end

        def convertible_container?(entity)
          entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        end

        def active_path_snapshot(model)
          ActivePathController.new(model).snapshot
        end

        def activate_root_context(model)
          ActivePathController.new(model).close_to_root
        end

        def restore_active_path(model, active_path)
          ActivePathController.new(model, logger: Logger).restore(active_path, close_when_nil: false)
        end

      end
    end
  end
end
