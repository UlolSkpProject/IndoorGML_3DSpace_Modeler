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
                rows << error_row('Feature', error['id'].to_s.empty? ? feature['id'] : error['id'], error)
              end
              Array(feature['primitives']).each do |primitive|
                Array(primitive['errors']).each do |error|
                  rows << error_row('Primitive', primitive['id'], error)
                end
              end
            end
            rows
          end

          def error_row(scope, item, error)
            {
              scope: scope,
              item: item,
              code: error['code'],
              description: error['description'] || error['type'] || 'UNKNOWN',
              raw: error
            }
          end

          def report_error_row_refs(row)
            text = [row[:item], row[:description], row[:raw]].map do |value|
              value.is_a?(Hash) ? value.to_json : value.to_s
            end.join(' ')
            {
              cells: text.scan(/cell_[A-Za-z0-9_.-]+/).uniq,
              states: text.scan(/state_[A-Za-z0-9_.-]+/).uniq,
              transitions: text.scan(/transition_[A-Za-z0-9_.-]+/).uniq
            }
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
        end

      end
    end
  end
end
