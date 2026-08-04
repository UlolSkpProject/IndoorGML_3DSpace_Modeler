# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'

require_relative 'val3dity_recheck_v3_mesh_proxy_boundary_dp_global_edge_support_repair'
require_relative 'val3dity_recheck_v3_mesh_proxy_benchmark'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only paired benchmark. It compares the initial production recheck
        # with the current v3 mesh proxy on the same ordered request list.
        # No v2 data is loaded or executed.
        module Val3dityRecheckV3MeshProxyPairedBenchmark
          MODE = 'recheck_only_initial_vs_v3_mesh_proxy_paired_benchmark'
          BASELINE_GLOB = File.join('initial_recheck_only', '*_recheck_only.json').freeze

          class << self
            attr_reader :last_result_path, :last_progress_log_path, :last_snapshot

            def run_snapshot(snapshot_dir, request_path: nil, baseline_path: nil,
                             manifest_path: nil, report_name: nil, output_dir: nil,
                             indoor_model: nil, time_budget_seconds: nil)
              snapshot_dir = directory!(snapshot_dir)
              request_path = file!(
                request_path || File.join(snapshot_dir, 'recheck_requests.json'),
                'Request JSON'
              )
              manifest_path = file!(
                manifest_path || File.join(snapshot_dir, 'manifest.json'),
                'Manifest JSON'
              )
              baseline_path = baseline_file(snapshot_dir, baseline_path)

              manifest = read_json(manifest_path)
              baseline = read_json(baseline_path)
              requests = Val3dityRecheckOnlyRunner.requests_from_file(request_path)
              baseline_run = validate_inputs!(
                manifest, baseline, requests, request_path
              )

              indoor_model ||= IndoorCore::IndoorModel.current
              unless indoor_model&.model == Sketchup.active_model
                raise 'IndoorModel.current is not bound to the active SketchUp model.'
              end

              baseline_ms = baseline_run.fetch('elapsed_ms').to_f
              budget_seconds = time_budget_seconds.nil? ?
                baseline_ms / 1000.0 : [time_budget_seconds.to_f, 0.0].max

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              name = sanitize(report_name || "initial_vs_v3_paired_#{stamp}")
              output_dir = File.expand_path(
                output_dir || File.join(snapshot_dir, 'paired_v3', stamp)
              )
              FileUtils.mkdir_p(output_dir)
              result_path = File.join(output_dir, "#{name}.json")
              progress_path = File.join(output_dir, 'progress.jsonl')
              @last_result_path = result_path
              @last_progress_log_path = progress_path

              benchmark = Val3dityRecheckV3MeshProxyBenchmark
              unless benchmark.singleton_class.private_method_defined?(:run_pipeline)
                raise 'V3 mesh proxy benchmark pipeline is unavailable.'
              end
              benchmark.instance_variable_set(:@last_result_path, result_path)
              benchmark.instance_variable_set(:@last_progress_log_path, progress_path)

              request_sha = Digest::SHA256.file(request_path).hexdigest
              live = nil
              File.open(progress_path, 'w:UTF-8') do |io|
                io.sync = true
                append(io, {
                  'event' => 'start',
                  'generated_at' => Time.now.iso8601(6),
                  'mode' => MODE,
                  'request_path' => request_path,
                  'baseline_path' => baseline_path,
                  'request_sha256' => request_sha,
                  'request_count' => requests.length,
                  'time_budget_seconds' => budget_seconds,
                  'v2_used' => false
                })
                live = benchmark.send(
                  :run_pipeline, requests, indoor_model, io, budget_seconds, false
                )
              end

              comparison = compare_pairs(
                baseline_run.fetch('results'), live.fetch('decisions')
              )
              completed = !live['aborted'] &&
                          live['processed_request_count'].to_i == requests.length &&
                          Array(live['errors']).empty?
              v3_ms = live['elapsed_ms'].to_f
              timing = {
                'initial_elapsed_ms' => baseline_ms.round(3),
                'v3_elapsed_ms' => v3_ms.round(3),
                'speedup_vs_initial' =>
                  (baseline_ms / v3_ms).round(3),
                'elapsed_reduction_ratio' =>
                  ((baseline_ms - v3_ms) / baseline_ms).round(6)
              }

              snapshot = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'mode' => MODE,
                'phase' => 'initial_production_vs_v3_global_edge_support',
                'production_code_modified' => false,
                'v2_used' => false,
                'v2_reference_path' => nil,
                'gml_export_skipped' => true,
                'val3dity_skipped' => true,
                'source_snapshot_directory' => snapshot_dir,
                'request_path' => request_path,
                'request_sha256' => request_sha,
                'manifest_path' => manifest_path,
                'baseline_path' => baseline_path,
                'progress_log_path' => progress_path,
                'request_count' => requests.length,
                'initial_production' => {
                  'elapsed_ms' => baseline_ms.round(3),
                  'status_counts' => counts(baseline_run['status_counts']),
                  'error_count' => baseline_run['error_count'].to_i
                },
                'v3_mesh_proxy' => live,
                'pair_comparison' => comparison,
                'timing_comparison' => timing,
                'completed' => completed,
                'benchmark_passed_for_next_stage' =>
                  completed && comparison['hard_gate_match'],
                'adoptable_for_production' => false,
                'production_adoption_blockers' => [
                  'multiple representative snapshots are not yet tested',
                  'direct cap reconstruction fallback cases require review',
                  'dev-only proxy implementation is not wired into production'
                ]
              }

              File.write(result_path, JSON.pretty_generate(snapshot), encoding: 'UTF-8')
              File.open(progress_path, 'a:UTF-8') do |io|
                append(io, {
                  'event' => 'finish',
                  'generated_at' => Time.now.iso8601(6),
                  'result_path' => result_path,
                  'processed_request_count' => live['processed_request_count'],
                  'aborted' => live['aborted'],
                  'error_count' => Array(live['errors']).length,
                  'status_mismatch_count' => comparison['status_mismatch_count'],
                  'hard_gate_mismatch_count' =>
                    comparison['hard_gate_mismatch_count'],
                  'speedup_vs_initial' => timing['speedup_vs_initial']
                })
              end

              @last_snapshot = snapshot
              snapshot
            end

            private

            def validate_inputs!(manifest, baseline, requests, request_path)
              actual_sha = Digest::SHA256.file(request_path).hexdigest
              expected_sha = manifest['request_sha256'].to_s.downcase
              unless !expected_sha.empty? && expected_sha == actual_sha
                raise "Request SHA-256 mismatch: #{expected_sha} != #{actual_sha}"
              end
              raise 'Manifest request count mismatch.' unless
                manifest['request_count'].to_i == requests.length

              unique_requests = requests.map do |row|
                [row['code'].to_i, Array(row['cells']).map(&:to_s).sort]
              end.uniq.length
              unique_pairs = requests.map do |row|
                Array(row['cells']).map(&:to_s).sort
              end.uniq.length
              raise 'Manifest unique request count mismatch.' unless
                manifest['unique_request_count'].to_i == unique_requests
              raise 'Manifest unique pair count mismatch.' unless
                manifest['unique_pair_count'].to_i == unique_pairs

              raise "Unexpected baseline mode: #{baseline['mode']}" unless
                baseline['mode'] == 'recheck_only'
              raise 'Baseline request count mismatch.' unless
                baseline['request_count'].to_i == requests.length
              source = baseline['source_path'].to_s
              unless source.empty? || normalize_path(source) == normalize_path(request_path)
                raise 'Baseline was created from a different request file.'
              end

              runs = Array(baseline['runs'])
              raise 'Baseline must contain exactly one run.' unless runs.length == 1
              run = runs.first
              raise 'Baseline run contains errors.' unless run['error_count'].to_i.zero?
              rows = Array(run['results'])
              raise 'Baseline pair result count mismatch.' unless
                rows.length == requests.length

              rows.each_with_index do |row, index|
                request = requests.fetch(index)
                validate_identity!(row, request, index, 'Baseline/request')
                nested = row['result']
                raise "Baseline result missing at index #{index}." unless nested.is_a?(Hash)
                validate_identity!(nested, request, index, 'Nested baseline/request')
              end
              raise 'Baseline status counts do not match pair results.' unless
                status_counts_from_baseline(rows) == counts(run['status_counts'])
              run
            end

            def compare_pairs(baseline_rows, v3_rows)
              baseline_rows = Array(baseline_rows)
              v3_rows = Array(v3_rows)
              v3_by_index = v3_rows.to_h { |row| [row['index'].to_i, row] }
              transitions = Hash.new(0)
              mismatches = []
              status_mismatch_count = 0

              baseline_rows.each_with_index do |baseline_row, index|
                initial = baseline_row.fetch('result')
                initial_values = decision_values(initial, true)
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

                validate_identity!(v3_row, baseline_row, index, 'V3/baseline')
                v3_values = decision_values(v3_row, false)
                transitions["#{initial_values['status']}->#{v3_values['status']}"] += 1
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
                    'path' => get(proxy, 'path'),
                    'fallback_reason' => get(proxy, 'fallback_reason'),
                    'repair_outcome' => repair_outcome(proxy),
                    'pair_elapsed_ms' => get(v3_row, 'pair_elapsed_ms')
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
                'status_match_count' => baseline_rows.length - status_mismatch_count,
                'status_mismatch_count' => status_mismatch_count,
                'hard_gate_match_count' => baseline_rows.length - mismatches.length,
                'hard_gate_mismatch_count' => mismatches.length,
                'all_statuses_match' => pair_count_match && status_mismatch_count.zero?,
                'hard_gate_match' => pair_count_match && mismatches.empty?,
                'mismatches' => mismatches
              }
            end

            def decision_values(row, baseline)
              volume_key = baseline ? 'actual_overlap_volume_mm3' : 'actual_overlap_volume'
              {
                'status' => get(row, 'status').to_s,
                'tolerated' => get(row, 'tolerated'),
                'reason' => get(row, 'reason').to_s,
                'intersection_component_count' =>
                  integer_or_nil(get(row, 'intersection_component_count')),
                'volume_class' => volume_class(get(row, volume_key))
              }
            end

            def validate_identity!(row, expected, index, label)
              matches = row['index'].nil? || row['index'].to_i == index
              matches &&= row['code'].to_i == expected['code'].to_i
              matches &&= Array(row['cells']) == Array(expected['cells'])
              raise "#{label} identity mismatch at index #{index}." unless matches
            end

            def repair_outcome(proxy)
              get(proxy, 'repair_outcome') || get(proxy, 'repair_status') ||
                get(get(proxy, 'repair'), 'outcome') ||
                get(get(proxy, 'rebuild_repair'), 'outcome')
            end

            def volume_class(raw)
              return 'nil' if raw.nil?
              value = raw.to_f
              return 'zero' if value.abs <= 1.0e-12

              value.positive? ? 'positive' : 'negative'
            end

            def integer_or_nil(raw)
              raw.nil? ? nil : raw.to_i
            end

            def get(hash, key)
              return nil unless hash.is_a?(Hash)
              return hash[key] if hash.key?(key)

              symbol = key.to_sym
              hash.key?(symbol) ? hash[symbol] : nil
            end

            def status_counts_from_baseline(rows)
              Array(rows).each_with_object(Hash.new(0)) do |row, result|
                result[get(row['result'], 'status').to_s] += 1
              end.sort.to_h
            end

            def status_counts_from_v3(rows)
              Array(rows).each_with_object(Hash.new(0)) do |row, result|
                result[get(row, 'status').to_s] += 1
              end.sort.to_h
            end

            def counts(source)
              Hash(source).transform_keys(&:to_s).transform_values(&:to_i).sort.to_h
            end

            def baseline_file(snapshot_dir, explicit)
              return file!(explicit, 'Initial production baseline JSON') if explicit

              path = Dir.glob(File.join(snapshot_dir, BASELINE_GLOB))
                .sort_by { |candidate| File.mtime(candidate) }.reverse.find do |candidate|
                  payload = read_json(candidate)
                  payload['mode'] == 'recheck_only' && Array(payload['runs']).length == 1
                rescue StandardError
                  false
                end
              raise 'Initial production baseline JSON was not found.' unless path

              File.expand_path(path)
            end

            def append(io, payload)
              io.write(JSON.generate(payload))
              io.write("\n")
              io.flush
            end

            def directory!(path)
              expanded = File.expand_path(path.to_s)
              raise "Snapshot directory was not found: #{expanded}" unless Dir.exist?(expanded)

              expanded
            end

            def file!(path, label)
              expanded = File.expand_path(path.to_s)
              raise "#{label} was not found: #{expanded}" unless File.file?(expanded)

              expanded
            end

            def normalize_path(path)
              File.expand_path(path.to_s).tr('\\', '/').downcase
            end

            def read_json(path)
              JSON.parse(File.read(path, encoding: 'UTF-8'))
            end

            def sanitize(value)
              text = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              text.empty? ? 'initial_vs_v3_paired' : text
            end
          end
        end
      end
    end
  end
end
