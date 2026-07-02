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
            @visible_storeys = Array(storeys).dup
            @visible_cell_types = Array(cell_types).dup
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
            return if @edit_mode_visibility_snapshots.key?(persistent_id)

            @edit_mode_visibility_snapshots[persistent_id] =
              snapshot || capture_cell_space_visibility(group)
          rescue StandardError
            nil
          end

          def cell_space_visibility_target?(group)
            group&.valid? && group.respond_to?(:visible=) && group.respond_to?(:entities)
          rescue StandardError
            false
          end

          def capture_cell_space_visibility(group)
            {
              visible: group.respond_to?(:visible?) ? group.visible? : true,
              children: visibility_child_entities(group).map { |entity| [entity, entity.hidden?] }
            }
          end

          def restore_cell_space_visibility(group, snapshot)
            return set_cell_space_render_visible(group, snapshot == true) unless snapshot.is_a?(Hash)

            Array(snapshot[:children]).each do |entity, hidden|
              next unless entity&.valid? && entity.respond_to?(:hidden=)

              entity.hidden = hidden == true
            end
            @cell_space_render_visibility[group.persistent_id] = true if group&.valid?
            true
          end

          def set_cell_space_render_visible(group, visible, snapshot = nil)
            return restore_cell_space_visibility(group, snapshot) if visible && snapshot

            persistent_id = group.persistent_id
            target_visible = visible == true
            return true if @cell_space_render_visibility[persistent_id] == target_visible

            visibility_child_entities(group).each { |entity| entity.hidden = visible != true }
            @cell_space_render_visibility[persistent_id] = target_visible
            true
          end

          def visibility_child_entities(group)
            group.entities.to_a.select do |entity|
              entity&.valid? && entity.respond_to?(:hidden?) && entity.respond_to?(:hidden=)
            end
          rescue StandardError
            []
          end
        end
      end
    end
  end
end
