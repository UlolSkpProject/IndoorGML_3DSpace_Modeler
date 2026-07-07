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

          def report_error_row_refs(row)
            text = [row[:item], row[:description], row[:raw], row[:context]].map do |value|
              value.is_a?(Hash) ? value.to_json : value.to_s
            end.join(' ')
            {
              cells: text.scan(/cell_[A-Za-z0-9_.-]+/).uniq,
              states: text.scan(/state_[A-Za-z0-9_.-]+/).uniq,
              transitions: text.scan(/transition_[A-Za-z0-9_.-]+/).uniq
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

              row_refs = report_error_row_refs(row)
              refs[:cells].concat(row_refs[:cells])
              refs[:states].concat(row_refs[:states])
              refs[:transitions].concat(row_refs[:transitions])
            end
            refs.each_value(&:uniq!)
            refs
          end

          def final_error_row_refs(row, raw_report = nil)
            recheck_row = matching_overlap_recheck_row(row, raw_report)
            if recheck_row
              raw_refs = report_error_row_refs(row)
              return {
                cells: Array(recheck_row['cells']).map(&:to_s).reject(&:empty?).uniq,
                states: raw_refs[:states],
                transitions: raw_refs[:transitions]
              }
            end

            report_error_row_refs(row)
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

              cells = Array(row['cells']).map(&:to_s).reject(&:empty?)
              next if cells.empty?

              memo[code] ||= []
              memo[code].concat(cells)
              memo[code].uniq!
            end
          end

          def matching_overlap_recheck_row(row, raw_report)
            code = error_code_number(row && row[:code])
            return nil unless OVERLAP_RECHECK_CODES.include?(code)

            refs = report_error_row_refs(row)
            row_cells = refs[:cells]
            Array(raw_report && raw_report[OVERLAP_RECHECK_REPORT_KEY]).find do |recheck_row|
              next false if recheck_row['tolerated'] == true
              next false unless error_code_number(recheck_row['code']) == code

              cells = Array(recheck_row['cells']).map(&:to_s).reject(&:empty?)
              cells.any? && cells.all? { |cell_id| row_cells.include?(cell_id) }
            end
          end
        end

      end
    end
  end
end
