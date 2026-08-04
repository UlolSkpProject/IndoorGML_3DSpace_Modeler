# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

require_relative 'val3dity_recheck_v3_positive_control_policy_fix'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only sweep for the positive-overlap transition immediately above
        # the configured 701 recheck tolerance.
        #
        # This control keeps policy safety separate from SketchUp Boolean
        # reproduction fidelity. Any tolerated=true result for these known
        # positive overlaps is an unsafe suppression and a hard failure.
        module Val3dityRecheckV3PositiveTransitionSweep
          MODE = 'v3_partial_xy_positive_transition_sweep'
          DEFAULT_DEPTHS_MM = [
            0.0255, 0.026, 0.027, 0.028, 0.029, 0.03,
            0.032, 0.035, 0.04, 0.0508, 0.075, 0.1
          ].freeze
          DEFAULT_GRID_PAIRS = [[1, 1], [2, 3]].freeze
          DEFAULT_PATTERN_PAIRS = [
            %w[forward reverse],
            %w[checker row_stripes]
          ].freeze
          DEFAULT_ORDERS = %w[ab ba].freeze

          Tool = Val3dityRecheckV3PositiveControl

          class << self
            attr_reader :last_result_path, :last_progress_path, :last_report

            def run(depths_mm: DEFAULT_DEPTHS_MM,
                    grid_pairs: DEFAULT_GRID_PAIRS,
                    pattern_pairs: DEFAULT_PATTERN_PAIRS,
                    orders: DEFAULT_ORDERS,
                    repeats: 2,
                    output_dir: nil,
                    report_name: nil,
                    indoor_model: nil)
              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              output_dir ||= File.join(
                __dir__, 'recheck_snapshots', 'control_geometry',
                'positive_transition_sweep', stamp
              )
              FileUtils.mkdir_p(output_dir)

              report = Tool.run(
                grid_pairs: grid_pairs,
                pattern_pairs: pattern_pairs,
                depths_mm: depths_mm,
                orders: orders,
                repeats: repeats,
                output_dir: output_dir,
                report_name: report_name || "v3_positive_transition_#{stamp}",
                indoor_model: indoor_model
              )

              sweep = build_transition_summary(report.fetch('rows'))
              report['parent_mode'] = report['mode']
              report['mode'] = MODE
              report['transition_sweep'] = sweep
              report['pass'] = report['pass'] == true &&
                               sweep['unsafe_positive_suppression_count'].zero? &&
                               sweep['policy_disagreement_count'].zero?

              @last_result_path = Tool.last_result_path
              @last_progress_path = Tool.last_progress_path
              @last_report = report
              File.write(
                @last_result_path,
                JSON.pretty_generate(report),
                encoding: 'UTF-8'
              )
              report
            end

            def print_report(report = @last_report)
              raise 'No positive-transition report is available.' unless report

              Tool.print_report(report)
              sweep = report.fetch('transition_sweep')

              puts
              puts '=' * 118
              puts 'V3 POSITIVE TRANSITION SWEEP'
              puts '=' * 118
              puts format('%46s : %s', 'not_reproduced_positive_observed',
                          sweep['not_reproduced_positive_observed'])
              puts format('%46s : %s', 'unsafe_positive_suppression_count',
                          sweep['unsafe_positive_suppression_count'])
              puts format('%46s : %s', 'original_not_reproduced_count',
                          sweep['original_not_reproduced_count'])
              puts format('%46s : %s', 'v3_not_reproduced_count',
                          sweep['v3_not_reproduced_count'])
              puts format('%46s : %s', 'original_all_reproduced_from_depth_mm',
                          sweep['original_all_reproduced_from_depth_mm'])
              puts format('%46s : %s', 'v3_all_reproduced_from_depth_mm',
                          sweep['v3_all_reproduced_from_depth_mm'])
              puts format('%46s : %s', 'policy_disagreement_count',
                          sweep['policy_disagreement_count'])
              puts format('%46s : %s', 'TRANSITION PASS', report['pass'])
              puts '-' * 118
              puts format(
                '%9s | %5s | %5s | %5s | %5s | %7s | %7s | %7s | %7s',
                'depth', 'rows', 'o_rep', 'v_rep', 'o_non', 'v_non',
                'o_incon', 'v_incon', 'unsafe'
              )
              puts '-' * 118
              Array(sweep['depth_summaries']).each do |entry|
                puts format(
                  '%9.5f | %5d | %5d | %5d | %5d | %7d | %7d | %7d | %7d',
                  entry['depth_mm'],
                  entry['row_count'],
                  entry['original_reproduced_count'],
                  entry['v3_reproduced_count'],
                  entry['original_not_reproduced_count'],
                  entry['v3_not_reproduced_count'],
                  entry['original_inconclusive_policy_count'],
                  entry['v3_inconclusive_policy_count'],
                  entry['unsafe_positive_suppression_count']
                )
              end
              puts '=' * 118
              nil
            end

            private

            def build_transition_summary(rows)
              depth_summaries = rows.group_by do |row|
                row['depth_mm'].to_f
              end.map do |depth, depth_rows|
                summarize_depth(depth, depth_rows)
              end.sort_by { |entry| entry['depth_mm'] }

              original_not_reproduced = rows.count do |row|
                row.dig('original', 'status') == 'not_reproduced'
              end
              v3_not_reproduced = rows.count do |row|
                row.dig('v3', 'status') == 'not_reproduced'
              end
              unsafe_rows = rows.count do |row|
                unsafe_positive_suppression?(row)
              end

              {
                'row_count' => rows.length,
                'not_reproduced_positive_observed' =>
                  original_not_reproduced.positive? ||
                  v3_not_reproduced.positive?,
                'original_not_reproduced_count' => original_not_reproduced,
                'v3_not_reproduced_count' => v3_not_reproduced,
                'original_not_reproduced_suppressed_count' => rows.count do |row|
                  row.dig('original', 'status') == 'not_reproduced' &&
                    row.dig('original_policy_701', 'tolerated') == true
                end,
                'v3_not_reproduced_suppressed_count' => rows.count do |row|
                  row.dig('v3', 'status') == 'not_reproduced' &&
                    row.dig('v3_policy_701', 'tolerated') == true
                end,
                'unsafe_positive_suppression_count' => unsafe_rows,
                'policy_disagreement_count' => rows.count do |row|
                  row['policy_disagreement'] == true
                end,
                'reproduction_warning_count' => rows.count do |row|
                  row['reproduction_warning'] == true
                end,
                'original_all_reproduced_from_depth_mm' =>
                  stable_all_reproduced_from_depth(depth_summaries, 'original'),
                'v3_all_reproduced_from_depth_mm' =>
                  stable_all_reproduced_from_depth(depth_summaries, 'v3'),
                'depth_summaries' => depth_summaries
              }
            end

            def summarize_depth(depth, rows)
              {
                'depth_mm' => depth,
                'expected_overlap_volume_mm3' =>
                  rows.first['expected_overlap_volume_mm3'],
                'row_count' => rows.length,
                'original_status_counts' => status_counts(rows, 'original'),
                'v3_status_counts' => status_counts(rows, 'v3'),
                'original_policy_status_counts' =>
                  policy_status_counts(rows, 'original_policy_701'),
                'v3_policy_status_counts' =>
                  policy_status_counts(rows, 'v3_policy_701'),
                'original_reproduced_count' => rows.count do |row|
                  row.dig('original', 'status') == 'reproduced'
                end,
                'v3_reproduced_count' => rows.count do |row|
                  row.dig('v3', 'status') == 'reproduced'
                end,
                'original_not_reproduced_count' => rows.count do |row|
                  row.dig('original', 'status') == 'not_reproduced'
                end,
                'v3_not_reproduced_count' => rows.count do |row|
                  row.dig('v3', 'status') == 'not_reproduced'
                end,
                'original_inconclusive_policy_count' => rows.count do |row|
                  row.dig('original_policy_701', 'status') == 'inconclusive'
                end,
                'v3_inconclusive_policy_count' => rows.count do |row|
                  row.dig('v3_policy_701', 'status') == 'inconclusive'
                end,
                'unsafe_positive_suppression_count' => rows.count do |row|
                  unsafe_positive_suppression?(row)
                end,
                'all_original_reproduced' => rows.all? do |row|
                  row.dig('original', 'status') == 'reproduced'
                end,
                'all_v3_reproduced' => rows.all? do |row|
                  row.dig('v3', 'status') == 'reproduced'
                end
              }
            end

            def status_counts(rows, key)
              rows.each_with_object(Hash.new(0)) do |row, counts|
                counts[row.dig(key, 'status').to_s] += 1
              end
            end

            def policy_status_counts(rows, key)
              rows.each_with_object(Hash.new(0)) do |row, counts|
                status = row.dig(key, 'status').to_s
                tolerated = row.dig(key, 'tolerated') == true
                counts["#{status}|tolerated=#{tolerated}"] += 1
              end
            end

            def unsafe_positive_suppression?(row)
              row.dig('original_policy_701', 'tolerated') == true ||
                row.dig('v3_policy_701', 'tolerated') == true
            end

            def stable_all_reproduced_from_depth(depth_summaries, prefix)
              depth_summaries.each_with_index do |entry, index|
                suffix = depth_summaries[index..]
                key = "all_#{prefix}_reproduced"
                return entry['depth_mm'] if suffix.all? { |item| item[key] == true }
              end
              nil
            end
          end
        end
      end
    end
  end
end
