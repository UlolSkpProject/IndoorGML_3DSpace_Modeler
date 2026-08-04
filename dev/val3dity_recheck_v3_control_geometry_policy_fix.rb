# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_control_geometry'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3ControlGeometry
          class << self
            def print_report(report = @last_report)
              raise 'No control-geometry report is available.' unless report

              puts
              puts '=' * 121
              puts 'V3 CONTROL GEOMETRY — OVERLAP DEPTH SWEEP'
              puts '=' * 121
              puts format(
                '%11s | %3s | %-14s | %-14s | %-29s | %12s | %s',
                'depth(mm)',
                'run',
                'original',
                'v3',
                'v3 path',
                'v3 vol(mm3)',
                'checks'
              )
              puts '-' * 121
              Array(report['rows']).each do |row|
                checks = []
                checks << 'REGRESSION' if row['original_kept_v3_missed']
                checks << 'FALSE_POSITIVE' if
                  row['nonpositive_depth_v3_reproduced']
                checks << 'TRANSITION_ZONE' if transition_row?(row)
                checks << '>CONFIG_TOL_DIAGNOSTIC' if
                  row['above_tolerance_v3_missed'] && !transition_row?(row)
                checks << 'OK' if checks.empty?

                puts format(
                  '%11.6f | %3d | %-14s | %-14s | %-29s | %12.6f | %s',
                  row['depth_mm'],
                  row['repeat'],
                  row.dig('original', 'status'),
                  row.dig('v3', 'status'),
                  row.dig('v3_proxy', 'path').to_s,
                  row.dig('v3', 'volume_mm3').to_f,
                  checks.join(',')
                )
              end

              puts '=' * 121
              summary = report.fetch('summary')
              puts "configured_tolerance_mm          : #{report['tolerance_mm']}"
              puts "row_count                        : #{summary['row_count']}"
              puts "raw_status_agreement_count       : #{summary['status_agreement_count']}"
              puts "original_kept_v3_missed          : #{summary['original_kept_v3_missed_count']}"
              puts "nonpositive_depth_false_pos      : #{summary['nonpositive_depth_v3_reproduced_count']}"
              puts "above_tolerance_diagnostic       : #{summary['above_tolerance_diagnostic_count']}"
              puts "transition_zone_depths_mm        : #{summary['transition_zone_depths_mm'].inspect}"
              puts "first_original_reproduced_any    : #{summary['first_original_reproduced_depth_mm']}"
              puts "first_v3_reproduced_any          : #{summary['first_v3_reproduced_depth_mm']}"
              puts "first_original_reproduced_all    : #{summary['first_original_consistent_reproduced_depth_mm']}"
              puts "first_v3_reproduced_all          : #{summary['first_v3_consistent_reproduced_depth_mm']}"
              puts "failure_count                    : #{summary['failure_count']}"
              puts "PASS                             : #{report['pass']}"
              puts "result_path                      : #{@last_result_path}"
              puts '=' * 121
              nil
            end

            private

            # The configured extension tolerance is not a guaranteed lower bound
            # for SketchUp Solid Boolean construction. A depth greater than that
            # value is therefore diagnostic only. The compatibility hard gates
            # are:
            #
            # 1. v3 must never miss an overlap reproduced by the original path.
            # 2. v3 must never create a positive solid for separation/contact.
            def summarize(rows, tolerance_mm)
              failures = rows.select do |row|
                row['original_kept_v3_missed'] ||
                  row['nonpositive_depth_v3_reproduced']
              end
              grouped = rows.group_by { |row| row['depth_mm'] }
              transition_depths = grouped.filter_map do |depth, depth_rows|
                raw_statuses = depth_rows.flat_map do |row|
                  [
                    row.dig('original', 'status'),
                    row.dig('v3', 'status'),
                    row.dig('v3_proxy', 'non_solid_safety_gate', 'proxy_status')
                  ]
                end.compact
                depth if raw_statuses.include?('non_solid') ||
                         raw_statuses.uniq.length > 2
              end.sort

              {
                'row_count' => rows.length,
                'status_agreement_count' =>
                  rows.count { |row| row['status_agreement'] },
                'original_kept_v3_missed_count' =>
                  rows.count { |row| row['original_kept_v3_missed'] },
                'nonpositive_depth_v3_reproduced_count' =>
                  rows.count { |row| row['nonpositive_depth_v3_reproduced'] },
                'above_tolerance_diagnostic_count' => rows.count do |row|
                  row['above_tolerance_v3_missed']
                end,
                'failure_count' => failures.length,
                'failure_depths_mm' =>
                  failures.map { |row| row['depth_mm'] }.uniq.sort,
                'transition_zone_depths_mm' => transition_depths,
                'tolerance_mm' => tolerance_mm,
                'first_original_reproduced_depth_mm' =>
                  first_reproduced_depth(rows, 'original'),
                'first_v3_reproduced_depth_mm' =>
                  first_reproduced_depth(rows, 'v3'),
                'first_original_consistent_reproduced_depth_mm' =>
                  first_consistent_reproduced_depth(grouped, 'original'),
                'first_v3_consistent_reproduced_depth_mm' =>
                  first_consistent_reproduced_depth(grouped, 'v3')
              }
            end

            def first_consistent_reproduced_depth(grouped, field)
              grouped.keys.sort.find do |depth|
                rows = grouped.fetch(depth)
                !rows.empty? && rows.all? do |row|
                  row.dig(field, 'status') == 'reproduced'
                end
              end
            end

            def transition_row?(row)
              statuses = [
                row.dig('original', 'status'),
                row.dig('v3', 'status'),
                row.dig('v3_proxy', 'non_solid_safety_gate', 'proxy_status')
              ].compact
              statuses.include?('non_solid')
            end
          end
        end
      end
    end
  end
end
