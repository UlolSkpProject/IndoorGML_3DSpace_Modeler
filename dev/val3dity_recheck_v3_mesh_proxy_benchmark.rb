# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

require_relative 'val3dity_recheck_snapshot_store'
require_relative 'val3dity_recheck_v3_mesh_proxy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Silent dev benchmark for the direct reconstructed v3 proxy.
        # Progress is appended to progress.jsonl; no console/logger/status output
        # is emitted. Baseline/v2/v3 references are read only.
        module Val3dityRecheckV3MeshProxyBenchmark
          MODE = 'recheck_only_v3_direct_mesh_proxy_benchmark'
          V2_REFERENCE_MODE = 'recheck_only_v2_fallback_timing'
          V3_REFERENCE_MODE = 'recheck_only_v3_benchmark'
          MIN_PROJECTED_SAMPLE = 50
          PROJECTED_ABORT_RATIO = 1.02

          class << self
            attr_reader :last_result_path, :last_progress_log_path, :last_snapshot

            def run_snapshot(name_or_path = nil, report_name: nil,
                             reference_path: nil, v3_reference_path: nil,
                             output_dir: nil, limit: nil, indoor_model: nil,
                             time_budget_seconds: nil,
                             abort_if_projected_slower: true)
              store = Val3dityRecheckSnapshotStore
              snapshot_dir = store.resolve_directory(name_or_path)
              request_path = store.request_path(name_or_path)
              raise 'Persistent recheck snapshot was not found.' unless
                snapshot_dir && request_path && File.file?(request_path)

              all_requests = Val3dityRecheckOnlyRunner.requests_from_file(request_path)
              raise 'Recheck request list is empty.' if all_requests.empty?

              requests = limit ? all_requests.first([limit.to_i, 0].max) : all_requests
              raise 'Selected recheck request list is empty.' if requests.empty?
              full_snapshot_run = requests.length == all_requests.length

              indoor_model ||= IndoorCore::IndoorModel.current
              raise 'IndoorModel.current is not bound to the active model.' unless
                indoor_model&.model == Sketchup.active_model

              frozen_v2_path = resolve_reference(
                reference_path,
                File.join(snapshot_dir, 'comparisons', '**', '*.json'),
                V2_REFERENCE_MODE,
                'Stored baseline/v2 comparison JSON was not found.'
              )
              frozen_v2 = read_json(frozen_v2_path)
              validate_v2_reference!(frozen_v2, request_path, all_requests)

              frozen_v3_path = resolve_optional_reference(
                v3_reference_path,
                File.join(snapshot_dir, 'benchmarks', 'v3', '**', '*.json'),
                V3_REFERENCE_MODE
              )
              frozen_v3 = frozen_v3_path ? read_json(frozen_v3_path) : nil

              baseline_ms = frozen_v2.dig('baseline', 'elapsed_ms').to_f
              budget_seconds = if time_budget_seconds.nil?
                                 baseline_ms / 1000.0
                               else
                                 [time_budget_seconds.to_f, 0.0].max
                               end

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              name = sanitize(report_name || "v3_direct_mesh_proxy_#{stamp}")
              directory = File.expand_path(
                output_dir || File.join(snapshot_dir, 'benchmarks', 'v3_mesh_proxy', stamp)
              )
              FileUtils.mkdir_p(directory)
              progress_path = File.join(directory, 'progress.jsonl')
              result_path = File.join(directory, "#{name}.json")
              @last_progress_log_path = progress_path
              @last_result_path = result_path

              live = nil
              File.open(progress_path, 'a:UTF-8') do |progress_io|
                progress_io.sync = true
                append_progress(progress_io, {
                  'event' => 'start',
                  'generated_at' => Time.now.iso8601(6),
                  'selected_request_count' => requests.length,
                  'snapshot_request_count' => all_requests.length,
                  'time_budget_seconds' => budget_seconds,
                  'baseline_reference_seconds' => baseline_ms / 1000.0,
                  'console_output' => false
                })
                live = run_pipeline(
                  requests,
                  indoor_model,
                  progress_io,
                  budget_seconds,
                  full_snapshot_run && abort_if_projected_slower == true
                )
              end

              baseline_counts = normalize_counts(frozen_v2.dig('baseline', 'status_counts') || {})
              live_counts = normalize_counts(live['status_counts'])
              aggregate_match = full_snapshot_run && !live['aborted'] && baseline_counts == live_counts
              v3_expected_closed = frozen_v3&.dig(
                'v3_gate_plus_fallback', 'v3_topology_success_pair_count'
              )
              v3_expected_open = frozen_v3&.dig(
                'v3_gate_plus_fallback', 'fallback_pair_count'
              )

              snapshot = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'mode' => MODE,
                'phase' => 'direct_clipped_mesh_reconstruction',
                'baseline_reexecuted' => false,
                'v2_reexecuted' => false,
                'v3_reference_reexecuted' => false,
                'val3dity_reexecuted' => false,
                'gml_export_skipped' => true,
                'production_code_modified' => false,
                'console_output_disabled' => true,
                'progress_log_path' => progress_path,
                'source_snapshot_directory' => snapshot_dir,
                'request_path' => request_path,
                'snapshot_request_count' => all_requests.length,
                'selected_request_count' => requests.length,
                'full_snapshot_run' => full_snapshot_run,
                'frozen_v2_reference_path' => frozen_v2_path,
                'frozen_v3_reference_path' => frozen_v3_path,
                'time_budget_seconds' => budget_seconds,
                'v3_mesh_proxy' => live,
                'aggregate_decision_comparison' => {
                  'available' => full_snapshot_run && !live['aborted'],
                  'baseline_status_counts' => baseline_counts,
                  'proxy_status_counts' => live_counts,
                  'status_counts_match' => aggregate_match,
                  'pair_level_baseline_available' => false
                },
                'v3_topology_reference' => {
                  'available' => !frozen_v3.nil?,
                  'expected_closed_pair_count' => v3_expected_closed,
                  'expected_open_pair_count' => v3_expected_open,
                  'current_direct_proxy_pair_count' => live['proxy_pair_count'],
                  'current_fallback_pair_count' => live['fallback_pair_count']
                },
                'timing_comparison' => {
                  'baseline_reference_elapsed_ms' => baseline_ms.round(3),
                  'v2_lower_bound_reference_elapsed_ms' =>
                    frozen_v2.dig('v2_gate_plus_fallback', 'elapsed_ms').to_f.round(3),
                  'v3_lower_bound_reference_elapsed_ms' =>
                    frozen_v3&.dig('v3_gate_plus_fallback', 'elapsed_ms').to_f.round(3),
                  'v3_mesh_proxy_elapsed_ms' => live['elapsed_ms'].to_f.round(3),
                  'speedup_vs_baseline' => ratio(baseline_ms, live['elapsed_ms'].to_f)
                },
                'benchmark_passed_for_next_stage' =>
                  full_snapshot_run && !live['aborted'] && aggregate_match &&
                  Array(live['errors']).empty?,
                'adoptable_for_production' => false,
                'production_adoption_blockers' => [
                  'pair-level frozen baseline decisions are not yet stored',
                  'multiple representative snapshots are not yet tested',
                  'direct cap reconstruction fallback cases require review'
                ]
              }

              File.write(result_path, JSON.pretty_generate(snapshot), encoding: 'UTF-8')
              File.open(progress_path, 'a:UTF-8') do |io|
                io.sync = true
                append_progress(io, {
                  'event' => 'finish',
                  'generated_at' => Time.now.iso8601(6),
                  'result_path' => result_path,
                  'elapsed_ms' => live['elapsed_ms'],
                  'processed_request_count' => live['processed_request_count'],
                  'aborted' => live['aborted'],
                  'abort_reason' => live['abort_reason'],
                  'status_counts' => live['status_counts'],
                  'path_counts' => live['path_counts']
                })
              end

              @last_snapshot = snapshot
              snapshot
            end

            private

            def run_pipeline(requests, indoor_model, progress_io, budget_seconds, projected_abort)
              runner = Val3dityRunner.new(
                File.join(File.dirname(@last_result_path), '__recheck_only_input__.gml'),
                report_name: File.basename(@last_result_path, '.json'),
                work_dir: File.dirname(@last_result_path),
                indoor_model: indoor_model
              )
              rechecker = Val3dityRecheckV3MeshProxy::Rechecker.new(
                indoor_model: indoor_model,
                model: indoor_model.model,
                tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
                logger: nil
              )
              runner.instance_variable_set(:@overlap_geometry_rechecker, rechecker)

              started = clock
              statuses = Hash.new(0)
              decisions = []
              errors = []
              aborted = false
              abort_reason = nil

              requests.each_with_index do |request, index|
                elapsed_before = clock - started
                if budget_seconds.positive? && elapsed_before >= budget_seconds
                  aborted = true
                  abort_reason = 'baseline_time_budget_exceeded_before_next_pair'
                  break
                end

                pair_started = clock
                result = runner.send(
                  :recheck_cell_pair,
                  request['code'], request['cells'][0], request['cells'][1]
                )
                pair_ms = elapsed_ms(pair_started)
                status = fetch_value(result, 'status') || 'unknown'
                statuses[status.to_s] += 1
                record = rechecker.proxy_record(request['cells'][0], request['cells'][1])
                decision = {
                  'index' => index,
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'status' => status.to_s,
                  'tolerated' => fetch_value(result, 'tolerated'),
                  'reason' => fetch_value(result, 'reason'),
                  'actual_overlap_volume' => fetch_value(result, 'actual_overlap_volume'),
                  'intersection_component_count' => fetch_value(result, 'intersection_component_count'),
                  'pair_elapsed_ms' => pair_ms,
                  'proxy' => record
                }
                decisions << decision

                processed = index + 1
                elapsed = clock - started
                projected_seconds = elapsed / processed * requests.length
                append_progress(progress_io, {
                  'event' => 'pair',
                  'generated_at' => Time.now.iso8601(6),
                  'index' => index,
                  'processed' => processed,
                  'total' => requests.length,
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'status' => status.to_s,
                  'path' => record && record['path'],
                  'fallback_reason' => record && record['fallback_reason'],
                  'pair_elapsed_ms' => pair_ms,
                  'elapsed_seconds' => elapsed.round(3),
                  'projected_total_seconds' => projected_seconds.round(3)
                })

                if budget_seconds.positive? && elapsed >= budget_seconds
                  aborted = true
                  abort_reason = 'baseline_time_budget_exceeded_after_pair'
                  break
                end
                if projected_abort && processed >= MIN_PROJECTED_SAMPLE &&
                   projected_seconds > budget_seconds * PROJECTED_ABORT_RATIO
                  aborted = true
                  abort_reason = 'projected_total_slower_than_baseline'
                  break
                end
              rescue StandardError => e
                statuses['error'] += 1
                error = {
                  'index' => index,
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'error' => "#{e.class}: #{e.message}"
                }
                errors << error
                append_progress(progress_io, error.merge(
                  'event' => 'error',
                  'generated_at' => Time.now.iso8601(6)
                ))
              end

              records = rechecker.proxy_records.values
              fallback_records = records.select do |row|
                row['path'] == 'original_full_recheck_fallback'
              end
              proxy_records = records.select { |row| row['path'] == 'v3_direct_mesh_proxy' }

              {
                'mode' => Val3dityRecheckV3MeshProxy::MODE,
                'production_equivalent_pair_decisions' => false,
                'production_decision_logic_reused' => true,
                'source_crop_boolean_used' => false,
                'target_boolean_used' => true,
                'elapsed_ms' => elapsed_ms(started),
                'request_count' => requests.length,
                'processed_request_count' => decisions.length + errors.length,
                'aborted' => aborted,
                'abort_reason' => abort_reason,
                'status_counts' => statuses.sort.to_h,
                'path_counts' => records.map { |row| row['path'] || 'missing' }.tally.sort.to_h,
                'proxy_pair_count' => proxy_records.length,
                'fallback_pair_count' => fallback_records.length,
                'fallback_reason_counts' =>
                  fallback_records.map { |row| row['fallback_reason'] }.tally.sort.to_h,
                'intersection_status_counts' =>
                  records.map { |row| row['intersection_status'] || 'missing' }.tally.sort.to_h,
                'mesh_cache_entry_count' => rechecker.mesh_cache.length,
                'timings_ms' => timing_summary(records),
                'decisions' => decisions,
                'errors' => errors
              }
            end

            def timing_summary(records)
              %w[
                analysis_elapsed_ms
                proxy_build_elapsed_ms
                target_copy_elapsed_ms
                target_boolean_elapsed_ms
                fallback_elapsed_ms
                total_elapsed_ms
              ].to_h do |field|
                values = records.filter_map do |row|
                  value = row[field]
                  value.to_f if value.is_a?(Numeric)
                end.sort
                [field, summarize(values)]
              end
            end

            def summarize(values)
              return {
                'count' => 0, 'sum' => 0.0, 'mean' => nil,
                'median' => nil, 'p95' => nil, 'max' => nil
              } if values.empty?

              {
                'count' => values.length,
                'sum' => values.sum.round(3),
                'mean' => (values.sum / values.length).round(3),
                'median' => percentile(values, 0.5).round(3),
                'p95' => percentile(values, 0.95).round(3),
                'max' => values.last.round(3)
              }
            end

            def percentile(values, fraction)
              return values.first if values.length == 1

              position = fraction * (values.length - 1)
              lower = position.floor
              upper = position.ceil
              return values[lower] if lower == upper

              values[lower] + (values[upper] - values[lower]) * (position - lower)
            end

            def append_progress(io, payload)
              io.write(JSON.generate(payload))
              io.write("\n")
              io.flush
            end

            def resolve_reference(explicit_path, pattern, mode, missing_message)
              path = if explicit_path
                       validate_path(explicit_path)
                     else
                       latest_matching_json(pattern, mode)
                     end
              raise missing_message unless path

              path
            end

            def resolve_optional_reference(explicit_path, pattern, mode)
              explicit_path ? validate_path(explicit_path) : latest_matching_json(pattern, mode)
            end

            def validate_path(path)
              expanded = File.expand_path(path.to_s)
              raise "Reference JSON was not found: #{expanded}" unless File.file?(expanded)

              expanded
            end

            def latest_matching_json(pattern, mode)
              Dir.glob(pattern).sort_by { |path| File.mtime(path) }.reverse.find do |path|
                read_json(path)['mode'] == mode
              rescue StandardError
                false
              end
            end

            def validate_v2_reference!(reference, request_path, requests)
              raise "Unexpected v2 reference mode: #{reference['mode']}" unless
                reference['mode'] == V2_REFERENCE_MODE
              raise 'Frozen v2 reference request count does not match snapshot.' unless
                reference['request_count'].to_i == requests.length
              stored = reference['request_path'].to_s
              return if stored.empty?

              raise 'Frozen v2 reference was created from a different request file.' unless
                normalize_path(stored) == normalize_path(request_path)
            end

            def normalize_counts(counts)
              Hash(counts).transform_keys(&:to_s).transform_values(&:to_i).sort.to_h
            end

            def normalize_path(path)
              File.expand_path(path.to_s).tr('\\', '/').downcase
            end

            def read_json(path)
              JSON.parse(File.read(path, encoding: 'UTF-8'))
            end

            def fetch_value(hash, key)
              return nil unless hash.is_a?(Hash)

              hash[key] || hash[key.to_sym]
            end

            def sanitize(value)
              text = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              text.empty? ? 'v3_direct_mesh_proxy' : text
            end

            def ratio(a, b)
              b.positive? ? (a / b).round(3) : nil
            end

            def elapsed_ms(started)
              ((clock - started) * 1000.0).round(3)
            end

            def clock
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end
        end
      end
    end
  end
end
