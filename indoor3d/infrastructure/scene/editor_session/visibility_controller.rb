# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class VisibilityController
          def initialize
            @visible_storeys = []
            @visible_cell_types = []
            @edit_mode_visibility_snapshots = {}
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
            @edit_mode_visibility_snapshots = {}
            @cell_space_render_visibility = {}
          end

          def clear_edit_mode_snapshots
            @edit_mode_visibility_snapshots = {}
          end

          def edit_mode_visibility_snapshots_empty?
            @edit_mode_visibility_snapshots.empty?
          end

          def edit_mode_visibility_snapshot(group)
            return nil unless group&.valid?

            @edit_mode_visibility_snapshots[group.persistent_id]
          rescue StandardError
            nil
          end

          def edit_mode_visibility_snapshot?(group)
            return false unless group&.valid?

            @edit_mode_visibility_snapshots.key?(group.persistent_id)
          rescue StandardError
            false
          end

          def remember_edit_mode_visibility(group, snapshot: nil)
            persistent_id = group.persistent_id
            return false if @edit_mode_visibility_snapshots.key?(persistent_id)

            @edit_mode_visibility_snapshots[persistent_id] =
              snapshot || capture_cell_space_visibility(group)
            true
          rescue StandardError
            false
          end

          def cell_space_visibility_target?(group)
            group&.valid? && group_hidden_target?(group)
          rescue StandardError
            false
          end

          def capture_cell_space_visibility(group)
            {
              hidden: group_hidden?(group)
            }
          end

          def restore_cell_space_visibility(group, snapshot)
            return set_cell_space_render_visible(group, snapshot == true) unless snapshot.is_a?(Hash)

            target_hidden = snapshot.key?(:hidden) ? snapshot[:hidden] == true : snapshot[:visible] == false
            set_group_hidden(group, target_hidden)
            @cell_space_render_visibility[group.persistent_id] = !target_hidden if group&.valid?
            true
          end

          def set_cell_space_render_visible(group, visible, _snapshot = nil, **_options)
            persistent_id = group.persistent_id
            target_visible = visible == true

            target_hidden = !target_visible
            return true if @cell_space_render_visibility[persistent_id] == target_visible &&
                           group_hidden?(group) == target_hidden

            set_group_hidden(group, target_hidden)
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
