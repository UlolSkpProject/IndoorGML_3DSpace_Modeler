# frozen_string_literal: true

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
              UI.messagebox('IndoorGML runtime data refreshed.')
            end,
            failure: proc do |error|
              UI.messagebox("Runtime refresh failed:\n#{error.message}")
            end
          ) do
            indoor_model.refresh_runtime_data
          end

          indoor_model.refresh_runtime_data unless scheduled
        rescue StandardError => e
          UI.messagebox("Runtime refresh failed:\n#{e.message}")
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

        def move_groups_to_root_context(model, groups)
          return groups if model.active_path().nil?

          groups.map { |group| move_group_to_root_context(model, group) }.compact
        end

        def move_group_to_root_context(model, group)
          return group unless group&.valid?()

          transformation = Utils::Transformation.entity_transformation_in_active_context(group)
          copy = model.entities().add_instance(group.definition, transformation)
          copy = copy.to_group() if copy.respond_to?(:to_group)
          copy.make_unique() if copy.respond_to?(:make_unique)
          copy.name = group.name if copy.respond_to?(:name=)
          copy.material = group.material if copy.respond_to?(:material=)
          copy.layer = group.layer if copy.respond_to?(:layer=)
          copy.visible = group.visible?() if copy.respond_to?(:visible=)
          group.erase!() if group.valid?()
          copy
        end

      end
    end
  end
end
