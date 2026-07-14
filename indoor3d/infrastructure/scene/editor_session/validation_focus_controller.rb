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
            @focus_rows = {}
            @highlight_cell_ids = nil
            @highlight_code = nil
            @highlight_row_id = nil
            @rendering_option_snapshots = {}
          end

          attr_reader :highlight_code
          attr_reader :highlight_row_id

          def begin(cell_gml_ids)
            ids = normalize_ids(cell_gml_ids)
            return false if ids.empty?

            @cell_ids = id_hash(ids)
            true
          end

          def set_focus_rows(rows)
            @focus_rows = Array(rows).each_with_object({}) do |row, memo|
              row_id = row[:id].to_s
              next if row_id.empty?

              cells = normalize_cell_refs(row[:cells])
              focus_ids = normalize_ids(row[:focus_ids] || cells)
              memo[row_id] = {
                cells: cells,
                states: Array(row[:states]).map(&:to_s),
                transitions: Array(row[:transitions]).map(&:to_s),
                focus_ids: focus_ids,
                code: row[:code].to_s
              }
            end
            rebuild_focus_ids_from_rows if active? && !@focus_rows.empty?
            true
          end

          def active?
            @cell_ids.is_a?(Hash)
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

          def set_highlight(cell_gml_ids, code = nil, row_id: nil, row_cells: nil, states: nil, transitions: nil)
            ids = normalize_ids(cell_gml_ids)
            @highlight_cell_ids = ids.empty? ? nil : id_hash(ids)
            @highlight_code = code.to_s
            @highlight_row_id = row_id.to_s.empty? ? nil : row_id.to_s
            upsert_focus_row(
              @highlight_row_id,
              cells: row_cells,
              states: states,
              transitions: transitions,
              focus_ids: ids,
              code: code
            ) if @highlight_row_id
            true
          end

          def highlight_active?
            !@highlight_row_id.nil? || (@highlight_cell_ids.is_a?(Hash) && !@highlight_cell_ids.empty?)
          end

          def add_highlight_cell(cell_id)
            update_highlight_row_cells(add: cell_id)
          end

          def remove_highlight_cell(cell_id)
            remove_cell(cell_id).find { |payload| payload[:row_id] == @highlight_row_id }
          end

          def remove_cell(cell_id)
            apply_cell_mutation(removed: [cell_id])
          end

          def apply_cell_mutation(added: [], removed: [], active_row_id: @highlight_row_id)
            return [] unless active? && @focus_rows && !@focus_rows.empty?

            added_ids = normalize_cell_refs(added)
            removed_ids = normalize_cell_refs(removed)
            affected_rows = {}

            unless removed_ids.empty?
              @focus_rows.each do |row_id, row|
                cells = Array(row[:cells])
                updated_cells = cells.reject { |cell| removed_ids.include?(cell) }
                next if updated_cells == cells

                row[:cells] = updated_cells
                affected_rows[row_id] = true
              end
            end

            target_row_id = active_row_id.to_s
            target_row = @focus_rows[target_row_id] unless target_row_id.empty?
            if target_row && !added_ids.empty?
              cells = Array(target_row[:cells]).dup
              added_ids.each { |cell_id| cells << cell_id unless cells.include?(cell_id) }
              if cells != target_row[:cells]
                target_row[:cells] = cells
                affected_rows[target_row_id] = true
              end
            end

            affected_rows.each_key do |row_id|
              row = @focus_rows[row_id]
              row[:focus_ids] = normalize_ids(row[:cells])
            end
            sync_highlight_ids_from_row
            rebuild_focus_ids_from_rows
            affected_rows.keys.map { |row_id| focus_row_payload(row_id, @focus_rows[row_id]) }
          end

          def prune_missing_cells(cell_spaces)
            valid_cells = normalize_cell_refs(Array(cell_spaces).select { |cell| cell&.valid? }.map(&:id))
            stale_cells = @focus_rows.values.flat_map { |row| Array(row[:cells]) }.uniq - valid_cells
            apply_cell_mutation(removed: stale_cells)
          rescue StandardError
            []
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
            if @highlight_row_id || (@highlight_cell_ids.is_a?(Hash) && !@highlight_cell_ids.empty?)
              return false unless @highlight_cell_ids.is_a?(Hash)

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

          def clear
            @cell_ids = nil
            @focus_rows = {}
            @highlight_cell_ids = nil
            @highlight_code = nil
            @highlight_row_id = nil
          end

          def capture_and_apply_rendering_options(model, _focus_cell_count)
            capture_and_apply_rendering_option_keys(model, validation_focus_rendering_option_keys)
          end

          def capture_and_apply_hidden_rendering_options(model)
            capture_and_apply_rendering_option_keys(model, HIDDEN_RENDERING_OPTION_KEYS)
          end

          def capture_and_apply_rendering_option_keys(model, keys)
            options = model&.rendering_options
            return unless options

            changed = false
            Array(keys).each do |key|
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

          def normalize_cell_refs(values)
            Array(values).map { |value| normalize_cell_ref(value) }.reject(&:empty?).uniq
          end

          def normalize_cell_ref(value)
            safe_id = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
            return '' if safe_id.empty?

            safe_id.start_with?('cell_') ? safe_id.sub(/\Acell_/, '') : safe_id
          end

          def upsert_focus_row(row_id, cells: nil, states: nil, transitions: nil, focus_ids: nil, code: nil)
            return false if row_id.to_s.empty?

            row = (@focus_rows ||= {})[row_id] ||= {
              cells: [],
              states: [],
              transitions: [],
              focus_ids: [],
              code: ''
            }
            row[:cells] = normalize_cell_refs(cells) unless cells.nil?
            row[:states] = Array(states).map(&:to_s) unless states.nil?
            row[:transitions] = Array(transitions).map(&:to_s) unless transitions.nil?
            row[:focus_ids] = normalize_ids(focus_ids || row[:cells])
            row[:code] = code.to_s unless code.nil?
            rebuild_focus_ids_from_rows
            true
          end

          def update_highlight_row_cells(add: nil, remove: nil)
            return nil unless active? && @highlight_row_id

            row = @focus_rows && @focus_rows[@highlight_row_id]
            return nil unless row

            cells = Array(row[:cells]).dup
            add_id = normalize_cell_ref(add)
            remove_id = normalize_cell_ref(remove)
            cells << add_id unless add_id.empty? || cells.include?(add_id)
            cells.delete(remove_id) unless remove_id.empty?
            row[:cells] = cells
            row[:focus_ids] = normalize_ids(cells)
            sync_highlight_ids_from_row(row)
            rebuild_focus_ids_from_rows
            focus_row_payload(@highlight_row_id, row)
          end

          def sync_highlight_ids_from_row(row = nil)
            return false unless @highlight_row_id

            row ||= @focus_rows && @focus_rows[@highlight_row_id]
            return false unless row

            focus_ids = Array(row[:focus_ids])
            @highlight_cell_ids = focus_ids.empty? ? nil : id_hash(focus_ids)
            true
          end

          def rebuild_focus_ids_from_rows
            return false if @focus_rows.nil? || @focus_rows.empty?

            ids = @focus_rows.values.flat_map { |row| Array(row[:focus_ids]) }.uniq
            @cell_ids = id_hash(ids)
            true
          end

          def focus_row_payload(row_id, row)
            cells = Array(row[:cells]).dup
            {
              row_id: row_id,
              cells: cells,
              states: Array(row[:states]).dup,
              transitions: Array(row[:transitions]).dup,
              focus_ids: Array(row[:focus_ids]).dup,
              code: row[:code].to_s,
              label: focus_row_label(cells)
            }
          end

          def focus_row_label(cells)
            labels = Array(cells).map do |cell_id|
              safe_id = cell_id.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              next if safe_id.empty?

              safe_id.start_with?('cell_') ? safe_id : "cell_#{safe_id}"
            end.compact
            return 'No CellSpace' if labels.empty?

            labels.join(' and ')
          end

          def cell_gml_ids(cell_space)
            safe_id = cell_space.id.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
            return [] if safe_id.empty?

            ids = ["cell_#{safe_id}"]
            ids << safe_id if safe_id.start_with?('cell_')
            ids.uniq
          end

          def validation_focus_rendering_option_keys
            keys = HIDDEN_RENDERING_OPTION_KEYS.dup
            keys.concat(MULTI_FOCUS_RENDERING_OPTION_KEYS)
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
