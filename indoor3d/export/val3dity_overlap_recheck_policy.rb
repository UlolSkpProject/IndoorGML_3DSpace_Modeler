# frozen_string_literal: true

require 'json'

require_relative 'val3dity_report_schema'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class Val3dityOverlapRecheckPolicy
          REPORT_KEY = 'indoorgml_modeler_overlap_recheck'
          STRICT_VALIDITY_KEY = 'strict_val3dity_validity'
          EXTENSION_VALIDITY_KEY = 'extension_policy_validity'
          VALIDATION_STATUS_KEY = 'indoorgml_modeler_validation_status'
          STRICT_ERRORS_REPORT_KEY = 'indoorgml_modeler_strict_errors'
          RECHECKABLE_CODES = [701, 704].freeze

          def initialize(tolerance_mm:)
            @tolerance_mm = tolerance_mm
          end

          def preserve_strict_validation!(raw_report)
            raw_report[STRICT_VALIDITY_KEY] = raw_report['validity'] == true
            raw_report[STRICT_ERRORS_REPORT_KEY] = error_item_rows(raw_report).map do |row|
              {
                'scope' => row[:scope],
                'item' => row[:item],
                'code' => row[:code],
                'description' => row[:description]
              }
            end
          end

          def count_recheckable_errors(raw_report)
            count = Array(raw_report['dataset_errors']).count { |error| recheckable_error?(error) }
            Array(raw_report['features']).each do |feature|
              count += Array(feature['errors']).count { |error| recheckable_error?(error) }
              Array(feature['primitives']).each do |primitive|
                count += Array(primitive['errors']).count { |error| recheckable_error?(error) }
              end
            end
            count
          end

          def apply!(raw_report, on_result: nil, before_refresh: nil, &pair_rechecker)
            raise ArgumentError, 'pair_rechecker block is required' unless pair_rechecker

            raw_report.delete(REPORT_KEY)
            results = []

            remove_rechecked_errors!(
              Array(raw_report['dataset_errors']),
              results,
              raw_report['input_file'],
              on_result: on_result,
              pair_rechecker: pair_rechecker
            )

            Array(raw_report['features']).each do |feature|
              remove_rechecked_errors!(
                Array(feature['errors']),
                results,
                feature['id'],
                on_result: on_result,
                pair_rechecker: pair_rechecker
              )
              Array(feature['primitives']).each do |primitive|
                remove_rechecked_errors!(
                  Array(primitive['errors']),
                  results,
                  feature['id'],
                  primitive['id'],
                  on_result: on_result,
                  pair_rechecker: pair_rechecker
                )
              end
            end

            before_refresh&.call(results)
            raw_report[REPORT_KEY] = results unless results.empty?
            refresh_validity!(raw_report)
            results
          end

          def recheckable_error?(error)
            RECHECKABLE_CODES.include?(error_code_number(error && error['code']))
          end

          def recheck_result(code, cell_ids, tolerated, reason, status: nil, distance: nil, overlap_area: nil, normal_thickness: nil, actual_overlap_volume: nil, intersection_component_count: nil)
            {
              'code' => code,
              'cells' => cell_ids,
              'tolerated' => tolerated,
              'status' => status || (tolerated ? 'suppressed' : 'kept'),
              'reason' => reason,
              'tolerance_mm' => @tolerance_mm,
              'distance_mm' => distance.nil? ? nil : distance.to_f * 25.4,
              'normal_thickness_mm' => normal_thickness.nil? ? nil : normal_thickness.to_f * 25.4,
              'overlap_area_mm2' => overlap_area.nil? ? nil : overlap_area.to_f * 25.4 * 25.4,
              'actual_overlap_volume_mm3' => actual_overlap_volume.nil? ? nil : actual_overlap_volume.to_f * 25.4 * 25.4 * 25.4,
              'intersection_component_count' => intersection_component_count
            }
          end

          private

          def remove_rechecked_errors!(errors, results, *context, on_result:, pair_rechecker:)
            errors.delete_if do |error|
              result = recheck_error(error, *context, &pair_rechecker)
              next false unless result

              results << result
              on_result&.call(result)
              result['tolerated'] == true
            end
          end

          def recheck_error(error, *context)
            code = error_code_number(error['code'])
            return nil unless RECHECKABLE_CODES.include?(code)

            text = ([error] + context).map { |value| value.is_a?(Hash) ? value.to_json : value.to_s }.join(' ')
            cell_ids = text.scan(/cell_[A-Za-z0-9_.-]+/).uniq
            return recheck_result(code, [], false, 'cell pair not found in val3dity error') if cell_ids.length < 2

            yield(code, cell_ids[0], cell_ids[1])
          end

          def refresh_validity!(raw_report)
            Array(raw_report['features']).each do |feature|
              Array(feature['primitives']).each do |primitive|
                primitive['validity'] = Array(primitive['errors']).empty?
              end

              feature['validity'] = Array(feature['errors']).empty? &&
                                    Array(feature['primitives']).all? { |primitive| primitive['validity'] == true }
            end

            raw_report['validity'] = error_item_rows(raw_report).empty?
            raw_report[EXTENSION_VALIDITY_KEY] = raw_report['validity'] == true
            raw_report[VALIDATION_STATUS_KEY] = if raw_report[STRICT_VALIDITY_KEY] == true
                                                  'exact_valid'
                                                elsif raw_report[EXTENSION_VALIDITY_KEY] == true
                                                  'extension_policy_valid'
                                                else
                                                  'invalid'
                                                end
            refresh_overview_counts!(raw_report, 'features_overview', Array(raw_report['features']))
            refresh_overview_counts!(
              raw_report,
              'primitives_overview',
              Array(raw_report['features']).flat_map { |feature| Array(feature['primitives']) }
            )
            raw_report['all_errors'] = error_item_rows(raw_report).map { |row| row[:code] }.uniq
          end

          def refresh_overview_counts!(raw_report, key, items)
            overview = Array(raw_report[key])
            return if overview.empty?

            overview.each do |row|
              type = row['type']
              matching = items.select { |item| type.to_s.empty? || item['type'] == type }
              row['total'] = matching.length
              row['valid'] = matching.count { |item| item['validity'] == true }
            end
          end

          def error_code_number(code)
            Val3dityReportSchema.error_code_number(code)
          end

          def error_item_rows(raw_report)
            Val3dityReportSchema.error_item_rows(raw_report)
          end
        end

      end
    end
  end
end
