# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditModeSelectionProjection
        def initialize(cell_spaces:, states:, transitions:, editor_session:, visibility_filter:, tag_classifier: IndoorCore.method(:tag_cell_space_type_and_category))
          @cell_spaces = cell_spaces
          @states = states
          @transitions = transitions
          @editor_session = editor_session
          @visibility_filter = visibility_filter
          @tag_classifier = tag_classifier
        end

        def snapshot(selected_cell_spaces:, solid_jobs:)
          cell_spaces = Array(selected_cell_spaces)
          cell_spaces = [@editor_session.editing_cell_space].compact if cell_spaces.empty?
          cell_spaces = cell_spaces.select { |cell_space| cell_space&.valid? }

          projected = if cell_spaces.empty?
                        solid_groups_snapshot(solid_jobs) || empty_snapshot
                      elsif cell_spaces.length > 1
                        cell_spaces_snapshot(cell_spaces)
                      else
                        cell_space_snapshot(cell_spaces.first)
                      end

          projected.merge(visibility_filter: @visibility_filter)
        end

        private

        def cell_space_snapshot(cell_space)
          group = cell_space.sketchup_group
          {
            mode: 'cell_space',
            feature: 'CellSpace',
            id: cell_space.id,
            name: group&.name.to_s,
            cell_type: CellSpaceType.label(cell_space.cell_type),
            category_code: cell_space.category_code,
            classification: CellSpaceCategory.selection_value(cell_space.cell_type, cell_space.category_code),
            classification_locked: cell_space_type_change_locked_by_tag?([cell_space]),
            storey: cell_space.storey,
            storey_editable: true,
            storey_range_allowed: storey_range_allowed_for_cell_spaces([cell_space]),
            navigation_semantics_enabled: cell_space.navigable?,
            navigation_class: resolved_navigation_semantic_value(cell_space, :class_value),
            navigation_function: resolved_navigation_semantic_value(cell_space, :function_value),
            navigation_usage: resolved_navigation_semantic_value(cell_space, :usage_value),
            navigation_semantics_editable: cell_space.navigable?,
            transition_count: cell_space.duality_state&.transition_ids&.length.to_i,
            cell_geometry_editing: @editor_session.cell_space_geometry_editing?
          }
        end

        def cell_spaces_snapshot(cell_spaces)
          {
            mode: 'cell_spaces',
            cell_space_count: cell_spaces.length,
            classification: common_cell_space_classification(cell_spaces),
            classification_locked: cell_space_type_change_locked_by_tag?(cell_spaces),
            storey: multi_cell_space_storey_value(cell_spaces),
            storey_editable: !common_cell_space_type(cell_spaces).nil?,
            storey_range_allowed: storey_range_allowed_for_cell_spaces(cell_spaces)
          }
        end

        def empty_snapshot
          {
            mode: 'empty',
            cell_type_counts: cell_type_counts_snapshot,
            state_count: @states.count { |state| state&.valid? },
            total_transition_count: @transitions.count { |transition| transition&.valid? }
          }
        end

        def solid_groups_snapshot(jobs)
          jobs = Array(jobs)
          return nil if jobs.empty?

          {
            mode: 'solid_groups',
            solid_group_count: jobs.length,
            classification: solid_groups_classification(jobs),
            classification_locked: solid_groups_classification_locked_by_tag?(jobs)
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

        def solid_groups_classification(jobs)
          tag_classification = common_tag_classification(jobs)
          return tag_classification unless tag_classification.nil?

          CellSpaceCategory.selection_value(
            CellSpaceType::GENERAL,
            CellSpaceCategory.default_for(CellSpaceType::GENERAL)[:code]
          )
        end

        def solid_groups_classification_locked_by_tag?(jobs)
          !common_tag_classification(jobs).nil?
        end

        def common_tag_classification(groups_or_jobs)
          targets = groups_or_jobs.map do |item|
            item.is_a?(Hash) ? item[:target] : @tag_classifier.call(item)
          end
          return nil if targets.empty? || targets.any?(&:nil?)

          classifications = targets.map do |target|
            CellSpaceCategory.selection_value(target[0], target[1])
          end.uniq

          classifications.length == 1 ? classifications.first : nil
        end

        def common_cell_space_classification(cell_spaces)
          classifications = cell_spaces.map do |cell_space|
            CellSpaceCategory.selection_value(cell_space.cell_type, cell_space.category_code)
          end.uniq

          classifications.length == 1 ? classifications.first : nil
        end

        def common_cell_space_type(cell_spaces)
          types = cell_spaces.map(&:cell_type).uniq
          types.length == 1 ? types.first : nil
        end

        def multi_cell_space_storey_value(cell_spaces)
          storeys = cell_spaces.map { |cell_space| cell_space.storey.to_s }.reject(&:empty?).uniq
          return storeys.first if storeys.length == 1

          cell_spaces.first&.storey || CellSpace::DEFAULT_STOREY
        end

        def storey_range_allowed_for_cell_spaces(cell_spaces)
          cell_spaces = Array(cell_spaces).select { |cell_space| cell_space&.valid? }
          return false if cell_spaces.empty?

          cell_spaces.all? do |cell_space|
            cell_space.cell_type == CellSpaceType::TRANSITION &&
              %w[Stair Elevator].include?(cell_space.category_code.to_s)
          end
        end

        def resolved_navigation_semantic_value(cell_space, key)
          NavigationSemanticResolver.resolve(cell_space).public_send(key)
        rescue NavigationSemanticError
          nil
        end

        def cell_space_type_change_locked_by_tag?(cell_spaces)
          return false if cell_spaces.empty?

          cell_spaces.all? do |cell_space|
            target = @tag_classifier.call(cell_space.sketchup_group)
            target && cell_space.cell_type == target[0] && cell_space.category_code == target[1]
          end
        end
      end

    end
  end
end
