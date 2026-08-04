# frozen_string_literal: true

require 'json'
require 'time'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only post-processor for an existing initial-vs-v3 paired report.
        #
        # The paired benchmark stores the v3 decision's public fields and the
        # detailed proxy record separately. For non-suppressed v3 decisions,
        # `tolerated` is omitted rather than explicitly written as false. The
        # public `actual_overlap_volume` field is also omitted, while the proxy
        # record owns the authoritative intersection status/volume. Comparing
        # those omissions directly against the production baseline creates
        # false hard-gate mismatches for every pair.
        #
        # This post-processor does not execute geometry. It reads the frozen
        # baseline and the existing v3 decisions, applies semantic normalization,
        # and writes a corrected comparison beside the original report.
        module Val3dityRecheckV3MeshProxyPairedRecompare
          MODE = 'recheck_only_initial_vs_v3_mesh_proxy_paired_recompare'
          SOURCE_MODE =
            'recheck_only_initial_vs_v3_mesh_proxy_paired_benchmark'

          class << self
            attr_reader :last_result_path, :last_snapshot

            def run(source_path, output_path: nil)
              source_path = file!(source_path, 'Paired benchmark JSON')
              source = read_json(source_path)
              unless source['mode'] == SOURCE_MODE
                raise "Unexpected paired benchmark mode: #{source['mode']}"
              end

              baseline_path = file!(
                source['baseline_path'],
                'Initial production baseline JSON'
              )
              baseline = read_json(baseline_path)
              baseline_run = single_baseline_run!(baseline)
              baseline_rows = Array(baseline_run['results'])
              v3_rows = Array(source.dig('v3_mesh_proxy', 'decisions'))
              expected_count = source['request_count'].to_i

              unless baseline_rows.length == expected_count
                raise 'Baseline pair count does not match source report.'
              end
              unless v3_rows.length == expected_count
                raise 'V3 pair count does not match source report.'
              end

              comparison = compare_pairs(baseline_rows, v3_rows)
              transition_review = transition_review(comparison)

              output_path ||= default_output_path(source_path)
              output_path = File.expand_path(output_path.to_s)
              snapshot = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'mode' => MODE,
                'geometry_reexecuted' => false,
                'source_paired_report_path' => source_path,
                'baseline_path' => baseline_path,
                'request_path' => source['request_path'],
                'request_sha256' => source['request_sha256'],
                'request_count' => expected_count,
                'initial_production' => source['initial_production'],
                'v3_summary' => {
                  'elapsed_ms' => source.dig('v3_mesh_proxy', 'elapsed_ms'),
                  'status_counts' => source.dig('v3_mesh_proxy', 'status_counts'),
                  'path_counts' => source.dig('v3_mesh_proxy', 'path_counts'),
                  'fallback_reason_counts' =>
                    source.dig('v3_mesh_proxy', 'fallback_reason_counts')
                },
                'timing_comparison' => source['timing_comparison'],
                'normalization' => {
                  'v3_tolerated' =>
                    'missing/nil is normalized to status == suppressed',
                  'v3_volume_class' =>
                    'derived from proxy.intersection_status and proxy.intersection_volume_in3',
                  'non_solid_volume_class' => 'nil',
                  'not_reproduced_volume_class' => 'zero',
                  'reproduced_volume_class' =>
                    'sign of proxy.intersection_volume_in3'
                },
                'pair_comparison' => comparison,
                'transition_review' => transition_review,
                'benchmark_passed_for_next_stage' =>
                  comparison['hard_gate_match'],
                'adoptable_for_production' => false,
                'production_adoption_blockers' => [
                  'pair-level decisions still differ from the initial production baseline',
                  'initial inconclusive to suppressed transitions require independent proof',
                  'initial suppressed to inconclusive transitions are regressions',
                  'multiple representative snapshots are not yet tested'
                ]
              }

              File.write(
                output_path,
                JSON.pretty_generate(snapshot),
                encoding: 'UTF-8'
              )
              @last_result_path = output_path
              @last_snapshot = snapshot
              snapshot
            end

            private

            def compare_pairs(baseline_rows, v3_rows)
              v3_by_index = {}
              duplicate_indices = []
              v3_rows.each do |row|
                index = Integer(row.fetch('index'))
                duplicate_indices << index if v3_by_index.key?(index)
                v3_by_index[index] = row
              end
              unless duplicate_indices.empty?
                raise "Duplicate v3 indices: #{duplicate_indices.uniq.sort.join(', ')}"
              end

              transitions = Hash.new(0)
              mismatches = []
              status_mismatch_count = 0

              baseline_rows.each_with_index do |baseline_row, index|
                initial = baseline_row.fetch('result')
                initial_values = baseline_values(initial)
                v3_row = v3_by_index[index]

                unless v3_row
                  transitions["#{initial_values['status']}->missing"] += 1
                  status_mismatch_count += 1
                  mismatches << {
                    'index' => index,
                    'code' => baseline_row['code'],
                    'cells' => baseline_row['cells'],
                    'differences' => ['missing_v3_decision'],
                    'initial' => initial_values,
                    'v3' => nil
                  }
                  next
                end

                validate_identity!(v3_row, baseline_row, index)
                v3_values = v3_values(v3_row)
                transitions[
                  "#{initial_values['status']}->#{v3_values['status']}"
                ] += 1
                differences = initial_values.keys.select do |key|
                  initial_values[key] != v3_values[key]
                end
                next if differences.empty?

                status_mismatch_count += 1 if differences.include?('status')
                proxy = v3_row['proxy'] || {}
                mismatches << {
                  'index' => index,
                  'code' => baseline_row['code'],
                  'cells' => baseline_row['cells'],
                  'differences' => differences,
                  'initial' => initial_values,
                  'v3' => v3_values.merge(
                    'path' => proxy['path'],
                    'fallback_reason' => proxy['fallback_reason'],
                    'intersection_status' => proxy['intersection_status'],
                    'pair_elapsed_ms' => v3_row['pair_elapsed_ms']
                  )
                }
              end

              pair_count_match = baseline_rows.length == v3_rows.length
              {
                'baseline_pair_count' => baseline_rows.length,
                'v3_pair_count' => v3_rows.length,
                'compared_pair_count' => v3_by_index.keys.count do |index|
                  index >= 0 && index < baseline_rows.length
                end,
                'pair_count_match' => pair_count_match,
                'transition_counts' => transitions.sort.to_h,
                'status_counts_match' =>
                  status_counts_from_baseline(baseline_rows) ==
                    status_counts_from_v3(v3_rows),
                'status_match_count' =>
                  baseline_rows.length - status_mismatch_count,
                'status_mismatch_count' => status_mismatch_count,
                'hard_gate_match_count' =>
                  baseline_rows.length - mismatches.length,
                'hard_gate_mismatch_count' => mismatches.length,
                'all_statuses_match' =>
                  pair_count_match && status_mismatch_count.zero?,
                'hard_gate_match' => pair_count_match && mismatches.empty?,
                'mismatches' => mismatches
              }
            end

            def transition_review(comparison)
              transitions = comparison['transition_counts'] || {}
              {
                'stable_pair_count' => transitions.sum do |key, count|
                  from, to = key.split('->', 2)
                  from == to ? count.to_i : 0
                end,
                'initial_inconclusive_to_suppressed_count' =>
                  transitions.fetch('inconclusive->suppressed', 0).to_i,
                'initial_suppressed_to_inconclusive_count' =>
                  transitions.fetch('suppressed->inconclusive', 0).to_i,
                'initial_kept_changed_count' => transitions.sum do |key, count|
                  from, to = key.split('->', 2)
                  from == 'kept' && to != 'kept' ? count.to_i : 0
                end,
                'all_initial_kept_preserved' => transitions.none? do |key, count|
                  from, to = key.split('->', 2)
                  count.to_i.positive? && from == 'kept' && to != 'kept'
                end,
                'requires_geometry_equivalence_proof' =>
                  comparison['status_mismatch_count'].to_i.positive?
              }
            end

            def baseline_values(row)
              {
                'status' => row['status'].to_s,
                'tolerated' => !!row['tolerated'],
                'reason' => row['reason'].to_s,
                'intersection_component_count' =>
                  integer_or_nil(row['intersection_component_count']),
                'volume_class' => numeric_volume_class(
                  row['actual_overlap_volume_mm3']
                )
              }
            end

            def v3_values(row)
              status = row['status'].to_s
              tolerated = row['tolerated']
              tolerated = status == 'suppressed' if tolerated.nil?
              {
                'status' => status,
                'tolerated' => !!tolerated,
                'reason' => row['reason'].to_s,
                'intersection_component_count' =>
                  integer_or_nil(row['intersection_component_count']),
                'volume_class' => proxy_volume_class(row['proxy'] || {})
              }
            end

            def proxy_volume_class(proxy)
              case proxy['intersection_status'].to_s
              when 'not_reproduced'
                'zero'
              when 'reproduced'
                numeric_volume_class(proxy['intersection_volume_in3'])
              else
                'nil'
              end
            end

            def numeric_volume_class(raw)
              return 'nil' if raw.nil?

              value = raw.to_f
              return 'zero' if value.abs <= 1.0e-12

              value.positive? ? 'positive' : 'negative'
            end

            def validate_identity!(row, expected, index)
              matches = row['index'].to_i == index
              matches &&= row['code'].to_i == expected['code'].to_i
              matches &&= Array(row['cells']) == Array(expected['cells'])
              raise "V3/baseline identity mismatch at index #{index}." unless matches
            end

            def status_counts_from_baseline(rows)
              Array(rows).each_with_object(Hash.new(0)) do |row, result|
                result[row.fetch('result').fetch('status').to_s] += 1
              end.sort.to_h
            end

            def status_counts_from_v3(rows)
              Array(rows).each_with_object(Hash.new(0)) do |row, result|
                result[row.fetch('status').to_s] += 1
              end.sort.to_h
            end

            def integer_or_nil(raw)
              raw.nil? ? nil : raw.to_i
            end

            def single_baseline_run!(baseline)
              raise "Unexpected baseline mode: #{baseline['mode']}" unless
                baseline['mode'] == 'recheck_only'
              runs = Array(baseline['runs'])
              raise 'Baseline must contain exactly one run.' unless runs.length == 1
              raise 'Baseline run contains errors.' unless
                runs.first['error_count'].to_i.zero?

              runs.first
            end

            def default_output_path(source_path)
              extension = File.extname(source_path)
              basename = File.basename(source_path, extension)
              File.join(
                File.dirname(source_path),
                "#{basename}_recompared#{extension}"
              )
            end

            def file!(path, label)
              expanded = File.expand_path(path.to_s)
              raise "#{label} was not found: #{expanded}" unless File.file?(expanded)

              expanded
            end

            def read_json(path)
              JSON.parse(File.read(path, encoding: 'UTF-8'))
            end
          end
        end
      end
    end
  end
end
