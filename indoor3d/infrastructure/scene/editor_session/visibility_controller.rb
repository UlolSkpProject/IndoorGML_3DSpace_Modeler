# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class VisibilityController
          def initialize
            @visible_storeys = []
            @visible_cell_types = []
            @cell_space_render_visibility = {}
          end

          attr_reader :visible_storeys, :visible_cell_types

          def set_filter(storeys:, cell_types:)
            next_storeys = Array(storeys).dup
            next_cell_types = Array(cell_types).dup
            changed = @visible_storeys != next_storeys || @visible_cell_types != next_cell_types
            @visible_storeys = next_storeys
            @visible_cell_types = next_cell_types
            changed
          end

          def filter_active?
            @visible_storeys.any? || @visible_cell_types.any?
          end

          def reset_filter
            @visible_storeys = []
            @visible_cell_types = []
            @cell_space_render_visibility = {}
          end

          def cell_space_visibility_target?(group)
            group&.valid? && group_hidden_target?(group)
          rescue StandardError
            false
          end

          def set_cell_space_render_visible(group, visible, _snapshot = nil, **_options)
            return false unless cell_space_visibility_target?(group)

            persistent_id = group.persistent_id
            target_visible = visible == true

            target_hidden = !target_visible
            return true if @cell_space_render_visibility[persistent_id] == target_visible &&
                           group_hidden?(group) == target_hidden

            return false unless set_group_hidden(group, target_hidden)

            @cell_space_render_visibility[persistent_id] = target_visible
            true
          end

          private

          def group_hidden_target?(group)
            (group.respond_to?(:hidden?) && group.respond_to?(:hidden=)) ||
              (group.respond_to?(:visible?) && group.respond_to?(:visible=))
          end

          def group_hidden?(group)
            return group.hidden? == true if group.respond_to?(:hidden?)
            return group.visible? != true if group.respond_to?(:visible?)

            false
          end

          def set_group_hidden(group, hidden)
            target_hidden = hidden == true
            current_hidden = group_hidden?(group)
            return true if current_hidden == target_hidden

            if group.respond_to?(:hidden=)
              group.hidden = target_hidden
            elsif group.respond_to?(:visible=)
              group.visible = !target_hidden
            end
            true
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
