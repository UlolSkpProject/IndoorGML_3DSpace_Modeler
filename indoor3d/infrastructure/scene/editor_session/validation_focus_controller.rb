# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class ValidationFocusController
          HIDDEN_RENDERING_OPTION_KEYS = %w[
            ROPDrawHiddenObjects
            ROPDrawHiddenGeometry
            DrawHiddenObjects
            DrawHiddenGeometry
            DrawHidden
          ].freeze
          MULTI_FOCUS_RENDERING_OPTION_KEYS = %w[HideRestOfModel].freeze

          def initialize
            @cell_ids = nil
            @highlight_cell_ids = nil
            @highlight_code = nil
            @visibility_snapshots = {}
            @rendering_option_snapshots = {}
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

          def focus_id_count
            return 0 unless @cell_ids.is_a?(Hash)

            @cell_ids.length
          end

          def focus_cell_space?(cell_space)
            return true unless active?
            return false unless cell_space&.valid?

            cell_gml_ids(cell_space).any? { |id| @cell_ids[id] == true }
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
              cell_space&.valid? && cell_gml_ids(cell_space).any? { |id| @highlight_cell_ids[id] == true }
            end
          rescue StandardError
            []
          end

          def visible_cell_space?(cell_space)
            return true unless active?
            return false unless cell_space&.valid?
            if @highlight_cell_ids.is_a?(Hash) && !@highlight_cell_ids.empty?
              return cell_gml_ids(cell_space).any? { |id| @highlight_cell_ids[id] == true }
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
            options = model&.rendering_options
            return unless options

            changed = false
            validation_focus_rendering_option_keys(focus_cell_count).each do |key|
              next unless rendering_option_key?(options, key)

              @rendering_option_snapshots[key] = options[key] unless @rendering_option_snapshots.key?(key)
              next if options[key] == false

              options[key] = false
              changed = true
            end
            model&.active_view&.invalidate if changed
          end

          def restore_rendering_options(model)
            snapshots = @rendering_option_snapshots || {}
            return if snapshots.empty?

            options = model&.rendering_options
            if options
              snapshots.each do |key, value|
                options[key] = value if rendering_option_key?(options, key)
              end
            end
            @rendering_option_snapshots = {}
            model&.active_view&.invalidate
          rescue StandardError
            @rendering_option_snapshots = {}
            raise
          end

          def cell_gml_id(cell_space)
            cell_gml_ids(cell_space).first
          end

          private

          def normalize_ids(values)
            Array(values).flat_map { |value| focus_id_aliases(value) }.uniq
          end

          def id_hash(ids)
            ids.each_with_object({}) { |id, memo| memo[id] = true }
          end

          def focus_id_aliases(value)
            safe_id = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
            return [] if safe_id.empty?

            aliases = [safe_id]
            if safe_id.start_with?('solid_cell_')
              aliases << safe_id.sub(/\Asolid_/, '')
            elsif safe_id.start_with?('cell_cell_')
              aliases << safe_id.sub(/\Acell_/, '')
            elsif !safe_id.start_with?('cell_', 'state_', 'transition_')
              aliases << "cell_#{safe_id}"
            end
            aliases.uniq
          end

          def cell_gml_ids(cell_space)
            safe_id = cell_space.id.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
            return [] if safe_id.empty?

            ids = ["cell_#{safe_id}"]
            ids << safe_id if safe_id.start_with?('cell_')
            ids.uniq
          end

          def validation_focus_rendering_option_keys(focus_cell_count)
            keys = HIDDEN_RENDERING_OPTION_KEYS.dup
            keys.concat(MULTI_FOCUS_RENDERING_OPTION_KEYS) if focus_cell_count.to_i >= 2
            keys
          end

          def rendering_option_key?(options, key)
            return options.key?(key) if options.respond_to?(:key?)
            return options.keys.include?(key) if options.respond_to?(:keys)

            found = false
            if options.respond_to?(:each_key)
              options.each_key { |option_key| found = true if option_key == key }
            end
            found
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
