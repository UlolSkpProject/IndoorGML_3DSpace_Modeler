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
            @active = false
            @cell_ids = nil
            @focus_rows = {}
            @highlight_cell_ids = nil
            @highlight_code = nil
            @highlight_row_id = nil
            @rendering_option_snapshots = {}
          end

          attr_reader :highlight_code
          attr_reader :highlight_row_id

          def highlighted_row_id
            @highlight_row_id
          end

          def begin(cell_gml_ids)
            ids = normalize_ids(cell_gml_ids)
            return false if ids.empty?

            @cell_ids = id_hash(ids)
            @active = true
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
                code: row[:code].to_s,
                geometry_refs: duplicate_geometry_refs(row[:geometry_refs])
              }
            end
            rebuild_focus_ids_from_rows if active? && !@focus_rows.empty?
            true
          end

          def active?
            @active == true
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

          def set_highlight(cell_gml_ids, code = nil, row_id: nil, row_cells: nil, states: nil, transitions: nil, geometry_refs: nil)
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
              code: code,
              geometry_refs: geometry_refs
            ) if @highlight_row_id
            true
          end

          def highlight_active?
            @highlight_cell_ids.is_a?(Hash) && !@highlight_cell_ids.empty?
          end

          def add_highlight_cell(cell_id)
            update_highlight_row_cells(add: cell_id)
          end

          def remove_highlight_cell(cell_id)
            remove_cell(cell_id).find { |payload| payload[:row_id] == @highlight_row_id }
          end

          def remove_cell(cell_id)
            remove_id = normalize_cell_ref(cell_id)
            return [] if remove_id.empty? || @focus_rows.nil? || @focus_rows.empty?

            payloads = []
            @focus_rows.each do |row_id, row|
              cells = Array(row[:cells])
              next unless cells.include?(remove_id)

              row[:cells] = cells.reject { |cell| cell == remove_id }
              row[:focus_ids] = normalize_ids(row[:cells])
              payloads << focus_row_payload(row_id, row)
            end
            sync_highlight_ids_from_row
            rebuild_focus_ids_from_rows
            payloads
          end

          def reconcile_cells(valid_cell_ids)
            valid_ids = normalize_cell_refs(valid_cell_ids).each_with_object({}) do |cell_id, ids|
              ids[cell_id] = true
            end
            payloads = []
            @focus_rows.each do |row_id, row|
              cells = Array(row[:cells])
              retained = cells.select { |cell_id| valid_ids[cell_id] }
              next if retained == cells

              row[:cells] = retained
              row[:focus_ids] = normalize_ids(retained)
              payloads << focus_row_payload(row_id, row)
            end
            sync_highlight_ids_from_row
            rebuild_focus_ids_from_rows
            payloads
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

          def clear
            @active = false
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

          def focus_row(row_id)
            normalized_row_id = row_id.to_s
            return nil if normalized_row_id.empty?

            row = @focus_rows && @focus_rows[normalized_row_id]
            row ? focus_row_payload(normalized_row_id, row) : nil
          end

          def highlighted_row_cells
            row = focus_row(@highlight_row_id)
            row ? row[:cells] : []
          end

          def highlighted_row_focus_ids
            row = focus_row(@highlight_row_id)
            row ? row[:focus_ids] : []
          end

          def highlighted_row_include_cell?(cell_id)
            highlighted_row_cells.include?(normalize_cell_ref(cell_id))
          end

          def snapshot
            {
              active: @active == true,
              cell_ids: duplicate_hash(@cell_ids),
              focus_rows: duplicate_focus_rows(@focus_rows),
              highlight_cell_ids: duplicate_hash(@highlight_cell_ids),
              highlight_code: @highlight_code,
              highlight_row_id: @highlight_row_id
            }
          end

          def restore!(snapshot)
            @active = snapshot.key?(:active) ? snapshot[:active] == true : !snapshot[:cell_ids].nil?
            @cell_ids = duplicate_hash(snapshot[:cell_ids])
            @focus_rows = duplicate_focus_rows(snapshot[:focus_rows])
            @highlight_cell_ids = duplicate_hash(snapshot[:highlight_cell_ids])
            @highlight_code = snapshot[:highlight_code]
            @highlight_row_id = snapshot[:highlight_row_id]
            true
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

          def upsert_focus_row(row_id, cells: nil, states: nil, transitions: nil, focus_ids: nil, code: nil, geometry_refs: nil)
            return false if row_id.to_s.empty?

            row = (@focus_rows ||= {})[row_id] ||= {
              cells: [],
              states: [],
              transitions: [],
              focus_ids: [],
              code: '',
              geometry_refs: { faces: [] }
            }
            row[:cells] = normalize_cell_refs(cells) unless cells.nil?
            row[:states] = Array(states).map(&:to_s) unless states.nil?
            row[:transitions] = Array(transitions).map(&:to_s) unless transitions.nil?
            row[:focus_ids] = normalize_ids(focus_ids || row[:cells])
            row[:code] = code.to_s unless code.nil?
            row[:geometry_refs] = duplicate_geometry_refs(geometry_refs) unless geometry_refs.nil?
            rebuild_focus_ids_from_rows
            true
          end

          def update_highlight_row_cells(add: nil, remove: nil)
            return nil unless @highlight_row_id

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

          def duplicate_hash(value)
            value.is_a?(Hash) ? value.dup : value
          end

          def duplicate_geometry_refs(value)
            refs = value.is_a?(Hash) ? value : {}
            faces = refs[:faces] || refs['faces']
            overlap = refs[:overlap_recheck] || refs['overlap_recheck']
            {
              faces: Array(faces).filter_map do |face|
                next unless face.is_a?(Hash)

                cell_id = face[:cell_id] || face['cell_id']
                face_index = face[:face_index] || face['face_index']
                next if cell_id.to_s.empty? || face_index.nil?

                { cell_id: cell_id.to_s, face_index: face_index.to_i }
              end,
              overlap_recheck: duplicate_overlap_recheck(overlap)
            }
          end

          def duplicate_overlap_recheck(value)
            return nil unless value.is_a?(Hash)

            {
              cells: Array(value[:cells] || value['cells']).map(&:to_s),
              tolerated: value[:tolerated] == true || value['tolerated'] == true,
              status: (value[:status] || value['status']).to_s,
              reason: (value[:reason] || value['reason']).to_s,
              actual_overlap_volume_mm3: value[:actual_overlap_volume_mm3] ||
                value['actual_overlap_volume_mm3']
            }
          end

          def duplicate_focus_rows(rows)
            Hash(rows).each_with_object({}) do |(row_id, row), copy|
              copy[row_id] = {
                cells: Array(row[:cells]).dup,
                states: Array(row[:states]).dup,
                transitions: Array(row[:transitions]).dup,
                focus_ids: Array(row[:focus_ids]).dup,
                code: row[:code].to_s,
                geometry_refs: duplicate_geometry_refs(row[:geometry_refs])
              }
            end
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
              geometry_refs: duplicate_geometry_refs(row[:geometry_refs]),
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
