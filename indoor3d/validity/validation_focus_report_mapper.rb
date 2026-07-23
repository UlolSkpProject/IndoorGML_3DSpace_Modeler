# frozen_string_literal: true

require_relative 'val3dity_report_schema'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module ValidationFocusReportMapper
          module_function

          def error_focus_cell_ids(report, indoor_model)
            refs = Val3dityReportSchema.final_error_refs(report || {})
            cell_ids_for_refs(refs, indoor_model)
          end

          def focus_row_states(report, indoor_model)
            Val3dityReportSchema.grouped_error_item_rows(report || {}).map do |group|
              refs = Val3dityReportSchema.grouped_error_row_refs(group)
              {
                id: group[:id],
                code: group[:code].to_s,
                cells: Array(refs[:cells]).map(&:to_s),
                states: Array(refs[:states]).map(&:to_s),
                transitions: Array(refs[:transitions]).map(&:to_s),
                focus_ids: cell_ids_for_refs(refs, indoor_model),
                geometry_refs: geometry_refs_for_group(group)
              }
            end
          end

          def geometry_refs_for_group(group)
            faces = Array(group && group[:members]).flat_map do |member|
              geometry_reference_texts(member).flat_map do |text|
                text.scan(/polygon_(\d+)_cell_([A-Za-z0-9_.-]+)/).map do |index, cell_id|
                  {
                    cell_id: normalize_cell_ref(cell_id),
                    face_index: index.to_i
                  }
                end
              end
            end

            {
              faces: faces.uniq { |face| [face[:cell_id], face[:face_index]] },
              overlap_recheck: overlap_recheck_geometry_ref(group && group[:overlap_recheck])
            }
          end

          def overlap_recheck_geometry_ref(row)
            return nil unless row.is_a?(Hash)

            {
              cells: Array(row['cells'] || row[:cells]).map { |cell| normalize_cell_ref(cell) },
              tolerated: row['tolerated'] == true || row[:tolerated] == true,
              status: (row['status'] || row[:status]).to_s,
              reason: (row['reason'] || row[:reason]).to_s,
              actual_overlap_volume_mm3: row['actual_overlap_volume_mm3'] ||
                row[:actual_overlap_volume_mm3]
            }
          end

          def geometry_reference_texts(value)
            case value
            when Hash
              value.flat_map do |key, nested_value|
                geometry_reference_texts(key) + geometry_reference_texts(nested_value)
              end
            when Array
              value.flat_map { |item| geometry_reference_texts(item) }
            else
              [value.to_s]
            end
          end

          def normalize_cell_ref(value)
            safe = safe_id(value)
            safe.start_with?('cell_') ? safe.sub(/\Acell_/, '') : safe
          end

          def cell_ids_for_refs(refs, indoor_model)
            cell_ids = Array(refs[:cells]).flat_map { |cell_id| cell_ref_ids(cell_id) }

            indoor_model.states.each do |state|
              next unless state&.valid?
              next unless prefixed_gml_ids('state', state.id).any? { |id| Array(refs[:states]).include?(id) }

              cell = state.duality_cell
              cell_ids.concat(prefixed_gml_ids('cell', cell.id)) if cell&.valid?
            end

            indoor_model.transitions.each do |transition|
              next unless transition&.valid?
              next unless prefixed_gml_ids('transition', transition.id).any? { |id| Array(refs[:transitions]).include?(id) }

              [transition.state1&.duality_cell, transition.state2&.duality_cell].each do |cell|
                cell_ids.concat(prefixed_gml_ids('cell', cell.id)) if cell&.valid?
              end
            end

            cell_ids.compact.uniq
          end

          def cell_ref_ids(value)
            safe = safe_id(value)
            return [] if safe.empty?

            if safe.start_with?('solid_cell_')
              [safe.sub(/\Asolid_/, '')]
            elsif safe.start_with?('cell_')
              [safe]
            else
              ["cell_#{safe}"]
            end
          end

          def prefixed_gml_ids(prefix, value)
            safe = safe_id(value)
            return [] if safe.empty?

            ids = ["#{prefix}_#{safe}"]
            ids << safe if safe.start_with?("#{prefix}_")
            ids.uniq
          end

          def safe_id(value)
            value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
          end
        end
      end
    end
  end
end
