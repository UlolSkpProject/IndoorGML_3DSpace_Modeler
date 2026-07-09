# frozen_string_literal: true

require 'json'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        module Val3dityReportSchema
          OVERLAP_RECHECK_REPORT_KEY = 'indoorgml_modeler_overlap_recheck'
          STRICT_VALIDITY_KEY = 'strict_val3dity_validity'
          EXTENSION_VALIDITY_KEY = 'extension_policy_validity'
          VALIDATION_STATUS_KEY = 'indoorgml_modeler_validation_status'
          STRICT_ERRORS_REPORT_KEY = 'indoorgml_modeler_strict_errors'
          OVERLAP_RECHECK_CODES = [701, 704].freeze

          module_function

          def error_code_number(code)
            code.to_s[/\d+/].to_i
          end

          def error_kind_rows(raw_report)
            counts = Hash.new { |hash, key| hash[key] = { code: key, description: 'UNKNOWN', count: 0 } }
            error_item_rows(raw_report).each do |row|
              item = counts[row[:code]]
              item[:description] = row[:description]
              item[:count] += 1
            end
            counts.values.sort_by { |row| row[:code].to_s }
          end

          def error_item_rows(raw_report)
            rows = []
            Array(raw_report['dataset_errors']).each do |error|
              rows << error_row('Dataset', raw_report['input_file'], error)
            end
            Array(raw_report['features']).each do |feature|
              Array(feature['errors']).each do |error|
                rows << error_row(
                  'Feature',
                  error['id'].to_s.empty? ? feature['id'] : error['id'],
                  error,
                  context: { feature_id: feature['id'] }
                )
              end
              Array(feature['primitives']).each do |primitive|
                Array(primitive['errors']).each do |error|
                  rows << error_row(
                    'Primitive',
                    primitive['id'],
                    error,
                    context: { feature_id: feature['id'] }
                  )
                end
              end
            end
            rows
          end

          def sorted_error_item_rows(raw_report)
            sort_error_item_rows(error_item_rows(raw_report))
          end

          def sort_error_item_rows(rows)
            Array(rows).sort_by { |row| [row[:code].to_s, row[:description].to_s, error_item_label(row).to_s] }
          end

          def error_item_row_id(index)
            "validation-error-row-#{index.to_i}"
          end

          def error_row(scope, item, error, context: nil)
            {
              scope: scope,
              item: item,
              code: error['code'],
              description: error['description'] || error['type'] || 'UNKNOWN',
              raw: error,
              context: context
            }
          end

          def final_error_refs(raw_report)
            refs = { cells: [], states: [], transitions: [] }
            overlap_cells_by_code = final_overlap_recheck_cells_by_code(raw_report)
            error_item_rows(raw_report || {}).each do |row|
              code = error_code_number(row[:code])
              if overlap_cells_by_code.key?(code)
                refs[:cells].concat(overlap_cells_by_code[code])
                next
              end

              row_refs = canonical_error_row_refs(row)
              refs[:cells].concat(row_refs[:cells])
              refs[:states].concat(row_refs[:states])
              refs[:transitions].concat(row_refs[:transitions])
            end
            refs.each_value(&:uniq!)
            refs
          end

          def final_error_row_refs(row, raw_report = nil)
            recheck_row = matching_overlap_recheck_row(row, raw_report)
            canonical_refs = canonical_error_row_refs(row)
            if recheck_row
              return {
                cells: normalize_cell_refs(recheck_row['cells']),
                states: canonical_refs[:states],
                transitions: canonical_refs[:transitions]
              }
            end

            overlap_cells = overlap_error_row_cells(row)
            return canonical_refs.merge(cells: overlap_cells) unless overlap_cells.empty?

            canonical_refs
          end

          def error_item_label(row)
            item = row[:item].to_s
            cells = item.scan(/cell_[A-Za-z0-9_.-]+/)
            return cells.uniq.join(' and ') if cells.length >= 2

            row[:scope].to_s == 'Dataset' ? item : "#{row[:scope]} #{item}"
          end

          def total_count(overview)
            Array(overview).sum { |item| item['total'].to_i }
          end

          def valid_count(overview)
            Array(overview).sum { |item| item['valid'].to_i }
          end

          def invalid_count(overview)
            total_count(overview) - valid_count(overview)
          end

          def final_overlap_recheck_cells_by_code(raw_report)
            Array(raw_report && raw_report[OVERLAP_RECHECK_REPORT_KEY]).each_with_object({}) do |row, memo|
              next if row['tolerated'] == true

              code = error_code_number(row['code'])
              next unless OVERLAP_RECHECK_CODES.include?(code)

              cells = normalize_cell_refs(row['cells'])
              next if cells.empty?

              memo[code] ||= []
              memo[code].concat(cells)
              memo[code].uniq!
            end
          end

          def matching_overlap_recheck_row(row, raw_report)
            code = error_code_number(row && row[:code])
            return nil unless OVERLAP_RECHECK_CODES.include?(code)

            row_cells = overlap_error_row_cells(row)
            row_cells = canonical_error_row_refs(row)[:cells] if row_cells.empty?
            candidates = Array(raw_report && raw_report[OVERLAP_RECHECK_REPORT_KEY]).select do |recheck_row|
              next false if recheck_row['tolerated'] == true
              next false unless error_code_number(recheck_row['code']) == code

              normalize_cell_refs(recheck_row['cells']).any?
            end
            exact_match = candidates.find do |recheck_row|
              cells = normalize_cell_refs(recheck_row['cells'])
              cells.sort == row_cells.sort
            end
            return exact_match if exact_match

            candidates.find do |recheck_row|
              cells = normalize_cell_refs(recheck_row['cells'])
              row_cells.any? { |cell_id| cells.include?(cell_id) }
            end
          end

          def canonical_error_row_refs(row)
            refs = empty_refs
            case row && row[:scope].to_s
            when 'Feature'
              add_feature_ref(refs, row.dig(:context, :feature_id))
            when 'Primitive'
              add_explicit_refs(refs, row[:item])
              add_explicit_refs(refs, row.dig(:raw, 'id'))
              add_explicit_refs(refs, row.dig(:raw, :id))
              add_feature_ref(refs, row.dig(:context, :feature_id)) if refs.values.all?(&:empty?)
            when 'Dataset'
              add_explicit_refs(refs, row[:item])
            else
              add_feature_ref(refs, row && row[:item])
            end
            refs
          end

          def add_explicit_refs(refs, value)
            text = value.to_s
            return if text.empty?

            refs[:cells].concat(cell_refs_from_text(text))
            refs[:states].concat(text.scan(/state_[A-Za-z0-9_.-]+/))
            refs[:transitions].concat(text.scan(/transition_[A-Za-z0-9_.-]+/))
            refs.each_value(&:uniq!)
          end

          def add_feature_ref(refs, value)
            text = value.to_s
            return if text.empty?

            if text.match?(/(?:cell|state|transition)_[A-Za-z0-9_.-]+/)
              add_explicit_refs(refs, text)
              return
            end

            id = safe_id(text)
            return if id.empty?

            if id.start_with?('state_')
              refs[:states] << id
            elsif id.start_with?('transition_')
              refs[:transitions] << id
            elsif id.start_with?('cell_')
              refs[:cells] << normalize_cell_ref(id)
            else
              refs[:cells] << id
            end
            refs.each_value(&:uniq!)
          end

          def overlap_error_row_cells(row)
            return [] unless OVERLAP_RECHECK_CODES.include?(error_code_number(row && row[:code]))

            values = [
              row && row[:item],
              row && row.dig(:raw, 'id'),
              row && row.dig(:raw, :id)
            ]
            values.flat_map { |value| cell_refs_from_text(value) }.uniq
          end

          def cell_refs_from_text(value)
            text = value.to_s
            return [] if text.empty?

            refs = text.scan(/(?:^|[^A-Za-z0-9_.-])((?:solid_)?cell_[A-Za-z0-9_.-]+)/).flatten
            refs.concat(
              text.scan(/(?:^|[^A-Za-z0-9_.-])polygon_[A-Za-z0-9_.-]*_cell_([A-Za-z0-9_.-]+)/)
                  .flatten
                  .map { |cell_id| "cell_#{cell_id}" }
            )
            refs.map { |cell_id| normalize_cell_ref(cell_id) }
                .reject(&:empty?)
                .uniq
          end

          def normalize_cell_refs(values)
            Array(values).map { |value| normalize_cell_ref(value) }.reject(&:empty?).uniq
          end

          def normalize_cell_ref(value)
            id = safe_id(value)
            return '' if id.empty?

            return id.sub(/\Asolid_cell_/, '') if id.start_with?('solid_cell_')

            id.start_with?('cell_') ? id.sub(/\Acell_/, '') : id
          end

          def safe_id(value)
            value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
          end

          def empty_refs
            { cells: [], states: [], transitions: [] }
          end
        end

      end
    end
  end
end
