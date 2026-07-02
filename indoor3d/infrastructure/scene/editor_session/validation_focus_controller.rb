# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class ValidationFocusController
          def initialize
            @cell_ids = nil
            @highlight_cell_ids = nil
            @highlight_code = nil
            @visibility_snapshots = {}
            @hide_rest_previous = nil
          end

          attr_reader :highlight_code

          def begin(cell_gml_ids)
            ids = normalize_ids(cell_gml_ids)
            return false if ids.empty?

            @cell_ids = id_hash(ids)
            true
          end

          def active?
            @cell_ids.is_a?(Hash) && !@cell_ids.empty?
          end

          def focus_cell_space?(cell_space)
            return true unless active?
            return false unless cell_space&.valid?

            @cell_ids[cell_gml_id(cell_space)] == true
          rescue StandardError
            false
          end

          def focus_cell_spaces(cell_spaces)
            return [] unless active?

            Array(cell_spaces).select { |cell_space| focus_cell_space?(cell_space) }
          rescue StandardError
            []
          end

          def set_highlight(cell_gml_ids, code = nil)
            ids = normalize_ids(cell_gml_ids)
            @highlight_cell_ids = ids.empty? ? nil : id_hash(ids)
            @highlight_code = code.to_s
            true
          end

          def highlight_cell_spaces(cell_spaces)
            return [] unless @highlight_cell_ids.is_a?(Hash) && !@highlight_cell_ids.empty?

            Array(cell_spaces).select do |cell_space|
              cell_space&.valid? && @highlight_cell_ids[cell_gml_id(cell_space)] == true
            end
          rescue StandardError
            []
          end

          def visible_cell_space?(cell_space)
            return true unless active?
            return false unless cell_space&.valid?
            if @highlight_cell_ids.is_a?(Hash) && !@highlight_cell_ids.empty?
              return @highlight_cell_ids[cell_gml_id(cell_space)] == true
            end

            focus_cell_space?(cell_space)
          rescue StandardError
            false
          end

          def elements(cell_spaces:, transitions:)
            cells = focus_cell_spaces(cell_spaces)
            cell_set = cells.each_with_object({}) { |cell, memo| memo[cell.object_id] = true }
            states = cells.map(&:duality_state).select { |state| state&.valid? }
            matching_transitions = Array(transitions).select do |transition|
              next false unless transition&.valid?

              cell1 = transition.state1&.duality_cell
              cell2 = transition.state2&.duality_cell
              cell1&.valid? && cell2&.valid? && cell_set[cell1.object_id] && cell_set[cell2.object_id]
            end

            {
              cell_spaces: cells,
              states: states,
              transitions: matching_transitions
            }
          rescue StandardError
            { cell_spaces: [], states: [], transitions: [] }
          end

          def visibility_snapshots
            @visibility_snapshots ||= {}
          end

          def visibility_snapshot(persistent_id)
            visibility_snapshots[persistent_id]
          end

          def visibility_snapshot?(persistent_id)
            visibility_snapshots.key?(persistent_id)
          end

          def remember_visibility_snapshot(persistent_id, snapshot)
            visibility_snapshots[persistent_id] = snapshot unless visibility_snapshots.key?(persistent_id)
          end

          def clear_visibility_snapshots
            @visibility_snapshots = {}
          end

          def clear
            @cell_ids = nil
            @highlight_cell_ids = nil
            @highlight_code = nil
            @visibility_snapshots = {}
          end

          def capture_and_apply_rendering_options(model, focus_cell_count)
            return unless focus_cell_count.to_i >= 2

            options = model&.rendering_options
            return unless options

            @hide_rest_previous = options['HideRestOfModel'] if @hide_rest_previous.nil?
            options['HideRestOfModel'] = false
            model&.active_view&.invalidate
          end

          def restore_rendering_options(model)
            return if @hide_rest_previous.nil?

            options = model&.rendering_options
            options['HideRestOfModel'] = @hide_rest_previous unless options.nil?
            @hide_rest_previous = nil
            model&.active_view&.invalidate
          rescue StandardError
            @hide_rest_previous = nil
            raise
          end

          def cell_gml_id(cell_space)
            "cell_#{cell_space.id.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')}"
          end

          private

          def normalize_ids(values)
            Array(values).map(&:to_s).reject(&:empty?)
          end

          def id_hash(ids)
            ids.each_with_object({}) { |id, memo| memo[id] = true }
          end
        end
      end
    end
  end
end
