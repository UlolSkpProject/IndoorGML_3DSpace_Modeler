# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

require_relative 'val3dity_recheck_snapshot_store'
require_relative 'val3dity_recheck_v3_box_proxy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only complete v3 proxy benchmark, phase 1.
        #
        # Live execution:
        #   v3 topology gate
        #   -> native AABB crop Boolean for the complex operand
        #   -> proxy manifold validation
        #   -> proxy-versus-target Boolean
        #   -> unchanged production 701/704 decision logic
        #   -> unchanged original full-solid fallback on any proxy failure
        #
        # Baseline and v2 are never re-executed. Their frozen JSON is read only.
        module Val3dityRecheckV3BoxProxyBenchmark
          SCHEMA_VERSION = 1
          DEFAULT_LOG_INTERVAL = 10
          V2_REFERENCE_MODE = 'recheck_only_v2_fallback_timing'
          V3_REFERENCE_MODE = 'recheck_only_v3_benchmark'

          class << self
            attr_reader :last_result_path, :last_snapshot

            def run_snapshot(name_or_path = nil, report_name: nil,
                             reference_path: nil, v3_reference_path: nil,
                             output_dir: nil,
                             console_interval: DEFAULT_LOG_INTERVAL,
                             limit: nil, indoor_model: nil)
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

              frozen_v2_path = resolve_v2_reference(snapshot_dir, reference_path)
              frozen_v2 = read_json(frozen_v2_path)
              validate_v2_reference!(frozen_v2, request_path, all_requests)
              frozen_v3_path = resolve_v3_reference(snapshot_dir, v3_reference_path)
              frozen_v3 = frozen_v3_path ? read_json(frozen_v3_path) : nil
              validate_v3_reference!(frozen_v3, all_requests) if frozen_v3

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              name = sanitize(report_name || "v3_box_proxy_#{stamp}")
              directory = File.expand_path(
                output_dir || File.join(snapshot_dir, 'benchmarks', 'v3_proxy', stamp)
              )
              FileUtils.mkdir_p(directory)

              log(
                "start selected=#{requests.length}/#{all_requests.length}, " \
                "snapshot=#{snapshot_dir}"
              )
              live = run_proxy_pipeline(
                requests, indoor_model, directory, name, console_interval
              )

              baseline_counts = normalize_counts(
                frozen_v2.dig('baseline', 'status_counts') || {}
              )
              live_counts = normalize_counts(live['status_counts'])
              aggregate_match = full_snapshot_run && baseline_counts == live_counts
              v3_regression = compare_v3_topology(
                live, frozen_v3, full_snapshot_run
              )

              snapshot = {
                'schema_version' => SCHEMA_VERSION,
                'generated_at' => Time.now.iso8601(6),
                'mode' => 'recheck_only_v3_native_aabb_proxy_benchmark',
                'phase' => 'phase_1_native_aabb_crop',
                'live_execution' => [
                  'v3_topology_gate',
                  'native_aabb_crop_boolean',
                  'proxy_manifold_validation',
                  'proxy_target_boolean',
                  'production_701_704_decision_logic',
                  'original_full_recheck_fallback_on_failure'
                ],
                'baseline_reexecuted' => false,
                'v2_reexecuted' => false,
                'val3dity_reexecuted' => false,
                'gml_export_skipped' => true,
                'production_code_modified' => false,
                'source_snapshot_directory' => snapshot_dir,
                'request_path' => request_path,
                'snapshot_request_count' => all_requests.length,
                'selected_request_count' => requests.length,
                'full_snapshot_run' => full_snapshot_run,
                'frozen_v2_reference_path' => frozen_v2_path,
                'frozen_v3_reference_path' => frozen_v3_path,
                'v3_box_proxy' => live,
                'aggregate_decision_comparison' => {
                  'available' => full_snapshot_run,
                  'baseline_status_counts' => baseline_counts,
                  'proxy_status_counts' => live_counts,
                  'status_counts_match' => aggregate_match,
                  'pair_level_baseline_available' => false,
                  'interpretation' =>
                    'aggregate match is necessary but not sufficient for production adoption'
                },
                'v3_topology_regression' => v3_regression,
                'timing_comparison' => timing_comparison(
                  frozen_v2, frozen_v3, live['elapsed_ms'].to_f
                ),
                'benchmark_passed_for_next_stage' =>
                  full_snapshot_run && aggregate_match &&
                  v3_regression.fetch('regressed', false) == false &&
                  Array(live['errors']).empty?,
                'adoptable_for_production' => false,
                'production_adoption_blockers' => [
                  'pair-level decision reference is not stored in the frozen baseline',
                  'native AABB crop Boolean is an intermediate proxy builder',
                  'manual clipped-mesh cap reconstruction is not implemented',
                  'multiple representative model snapshots are not yet tested'
                ]
              }

              path = File.join(directory, "#{name}.json")
              File.write(path, JSON.pretty_generate(snapshot), encoding: 'UTF-8')
              @last_snapshot = snapshot
              @last_result_path = path
              log("saved #{path}")
              log(summary_line(snapshot))
              snapshot
            ensure
              set_status('')
            end

            private

            def run_proxy_pipeline(requests, indoor_model, directory, name, interval)
              runner = Val3dityRunner.new(
                File.join(directory, '__recheck_only_input__.gml'),
                report_name: name,
                work_dir: directory,
                indoor_model: indoor_model
              )
              rechecker = Val3dityRecheckV3BoxProxy::Rechecker.new(
                indoor_model: indoor_model,
                model: indoor_model.model,
                tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
                logger: IndoorCore::Logger
              )
              runner.instance_variable_set(:@overlap_geometry_rechecker, rechecker)

              started = clock
              statuses = Hash.new(0)
              errors = []
              decisions = []

              requests.each_with_index do |request, index|
                pair_started = clock
                result = runner.send(
                  :recheck_cell_pair,
                  request['code'],
                  request['cells'][0],
                  request['cells'][1]
                )
                status = fetch_value(result, 'status') || 'unknown'
                statuses[status.to_s] += 1
                decisions << {
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'status' => status.to_s,
                  'tolerated' => fetch_value(result, 'tolerated'),
                  'reason' => fetch_value(result, 'reason'),
                  'distance' => fetch_value(result, 'distance'),
                  'overlap_area' => fetch_value(result, 'overlap_area'),
                  'actual_overlap_volume' =>
                    fetch_value(result, 'actual_overlap_volume'),
                  'intersection_component_count' =>
                    fetch_value(result, 'intersection_component_count'),
                  'pair_elapsed_ms' => elapsed_ms(pair_started),
                  'proxy' => rechecker.proxy_record(
                    request['cells'][0], request['cells'][1]
                  )
                }
                progress(index, requests.length, request, started, interval)
              rescue StandardError => e
                statuses['error'] += 1
                errors << error_row(request, index, e)
                progress(index, requests.length, request, started, interval, force: true)
              end

              records = rechecker.proxy_records.values
              path_counts = records.map { |row| row['path'] || 'missing' }.tally
              fallback_records = records.select do |row|
                row['path'] == 'original_full_recheck_fallback'
              end
              proxy_records = records.select { |row| row['path'] == 'v3_box_proxy' }
              gate_closed = records.count do |row|
                row.dig('v3_analysis', 'global_cap_graph_closed') == true
              end

              {
                'mode' => Val3dityRecheckV3BoxProxy::MODE,
                'production_equivalent_pair_decisions' => false,
                'production_decision_logic_reused' => true,
                'geometry_operand_changed' => true,
                'elapsed_ms' => elapsed_ms(started),
                'request_count' => requests.length,
                'status_counts' => statuses.sort.to_h,
                'path_counts' => path_counts.sort.to_h,
                'v3_gate_closed_pair_count' => gate_closed,
                'v3_gate_open_or_error_pair_count' => records.length - gate_closed,
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
              fields = %w[
                gate_elapsed_ms
                source_copy_elapsed_ms
                crop_box_build_elapsed_ms
                crop_boolean_elapsed_ms
                target_copy_elapsed_ms
                target_boolean_elapsed_ms
                fallback_elapsed_ms
                total_elapsed_ms
              ]
              fields.to_h do |field|
                values = records.filter_map do |row|
                  value = row[field]
                  value.to_f if value.is_a?(Numeric)
                end
                [field, summarize_values(values)]
              end
            end

            def summarize_values(values)
              sorted = values.sort
              return { 'count' => 0, 'sum' => 0.0, 'mean' => nil, 'median' => nil, 'p95' => nil, 'max' => nil } if sorted.empty?

              {
                'count' => sorted.length,
                'sum' => sorted.sum.round(3),
                'mean' => (sorted.sum / sorted.length).round(3),
                'median' => percentile(sorted, 0.50).round(3),
                'p95' => percentile(sorted, 0.95).round(3),
                'max' => sorted.last.round(3)
              }
            end

            def percentile(sorted, fraction)
              return sorted.first if sorted.length == 1

              position = fraction * (sorted.length - 1)
              lower = position.floor
              upper = position.ceil
              return sorted[lower] if lower == upper

              sorted[lower] + ((sorted[upper] - sorted[lower]) * (position - lower))
            end

            def compare_v3_topology(live, frozen_v3, full_snapshot_run)
              current_closed = live['v3_gate_closed_pair_count'].to_i
              current_open = live['v3_gate_open_or_error_pair_count'].to_i
              return {
                'reference_available' => false,
                'partial_run' => !full_snapshot_run,
                'current_closed_pair_count' => current_closed,
                'current_open_pair_count' => current_open,
                'regressed' => false
              } unless frozen_v3 && full_snapshot_run

              expected_closed = frozen_v3.dig(
                'v3_gate_plus_fallback', 'v3_topology_success_pair_count'
              ).to_i
              expected_open = frozen_v3.dig(
                'v3_gate_plus_fallback', 'fallback_pair_count'
              ).to_i
              {
                'reference_available' => true,
                'expected_closed_pair_count' => expected_closed,
                'expected_open_pair_count' => expected_open,
                'current_closed_pair_count' => current_closed,
                'current_open_pair_count' => current_open,
                'closed_pair_delta' => current_closed - expected_closed,
                'open_pair_delta' => current_open - expected_open,
                'regressed' => current_closed < expected_closed || current_open > expected_open
              }
            end

            def timing_comparison(frozen_v2, frozen_v3, proxy_ms)
              baseline_ms = frozen_v2.dig('baseline', 'elapsed_ms').to_f
              v2_ms = frozen_v2.dig('v2_gate_plus_fallback', 'elapsed_ms').to_f
              v3_ms = frozen_v3&.dig('v3_gate_plus_fallback', 'elapsed_ms').to_f
              {
                'baseline_reference_elapsed_ms' => baseline_ms.round(3),
                'v2_lower_bound_reference_elapsed_ms' => v2_ms.round(3),
                'v3_lower_bound_reference_elapsed_ms' => v3_ms.round(3),
                'v3_box_proxy_elapsed_ms' => proxy_ms.round(3),
                'speedup_vs_baseline' => ratio(baseline_ms, proxy_ms),
                'change_from_v3_lower_bound_percent' =>
                  v3_ms.positive? ? (((proxy_ms - v3_ms) / v3_ms) * 100.0).round(3) : nil,
                'reference_values_reused_without_reexecution' => true,
                'interpretation' =>
                  'complete phase-1 proxy path; native box crop is still intermediate'
              }
            end

            def resolve_v2_reference(snapshot_dir, explicit_path)
              return validate_explicit_path(explicit_path, 'Frozen baseline/v2 reference') if explicit_path

              find_latest_json(
                File.join(snapshot_dir, 'comparisons', '**', '*.json')
              ) { |payload| payload['mode'] == V2_REFERENCE_MODE }
                .tap { |path| raise 'Stored baseline/v2 comparison JSON was not found.' unless path }
            end

            def resolve_v3_reference(snapshot_dir, explicit_path)
              return validate_explicit_path(explicit_path, 'Frozen v3 reference') if explicit_path

              find_latest_json(
                File.join(snapshot_dir, 'benchmarks', 'v3', '**', '*.json')
              ) { |payload| payload['mode'] == V3_REFERENCE_MODE }
            end

            def validate_explicit_path(path, label)
              expanded = File.expand_path(path.to_s)
              raise "#{label} was not found: #{expanded}" unless File.file?(expanded)

              expanded
            end

            def find_latest_json(pattern)
              Dir.glob(pattern).sort_by { |path| File.mtime(path) }.reverse.find do |path|
                payload = read_json(path)
                yield(payload)
              rescue StandardError
                false
              end
            end

            def read_json(path)
              JSON.parse(File.read(path, encoding: 'UTF-8'))
            end

            def validate_v2_reference!(reference, request_path, requests)
              raise "Unexpected v2 reference mode: #{reference['mode']}" unless
                reference['mode'] == V2_REFERENCE_MODE
              raise 'Frozen v2 reference request count does not match snapshot.' unless
                reference['request_count'].to_i == requests.length
              reference_path = reference['request_path'].to_s
              return if reference_path.empty?

              same = normalize_path(reference_path) == normalize_path(request_path)
              raise 'Frozen v2 reference was created from a different request file.' unless same
            end

            def validate_v3_reference!(reference, requests)
              raise "Unexpected v3 reference mode: #{reference['mode']}" unless
                reference['mode'] == V3_REFERENCE_MODE
              raise 'Frozen v3 reference request count does not match snapshot.' unless
                reference['request_count'].to_i == requests.length
            end

            def normalize_counts(counts)
              Hash(counts).transform_keys(&:to_s).transform_values(&:to_i).sort.to_h
            end

            def normalize_path(path)
              File.expand_path(path.to_s).tr('\\', '/').downcase
            end

            def fetch_value(hash, key)
              return nil unless hash.is_a?(Hash)

              hash[key] || hash[key.to_sym]
            end

            def progress(index, total, request, started, interval, force: false)
              current = index + 1
              percent = total.zero? ? 100.0 : current.to_f / total * 100.0
              elapsed = clock - started
              eta = current.positive? ? elapsed / current * (total - current) : nil
              message = format(
                '[RecheckV3Proxy] %d/%d %.1f%% code=%d %s <-> %s elapsed=%s eta=%s',
                current, total, percent, request['code'],
                request['cells'][0], request['cells'][1],
                duration(elapsed), duration(eta)
              )
              set_status(message)
              log(message) if force || current == 1 || current == total ||
                              (interval.to_i.positive? && current % interval.to_i == 0)
            rescue StandardError
              nil
            end

            def set_status(text)
              Sketchup.set_status_text(text.to_s) if
                defined?(Sketchup) && Sketchup.respond_to?(:set_status_text)
            rescue StandardError
              nil
            end

            def error_row(request, index, error)
              {
                'index' => index,
                'code' => request['code'],
                'cells' => request['cells'],
                'error' => "#{error.class}: #{error.message}"
              }
            end

            def ratio(a, b)
              b.positive? ? (a / b).round(3) : nil
            end

            def sanitize(value)
              text = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              text.empty? ? 'v3_box_proxy' : text
            end

            def duration(seconds)
              return '--' unless seconds&.finite?

              total = [seconds.round, 0].max
              hours = total / 3600
              minutes = total % 3600 / 60
              secs = total % 60
              hours.positive? ? format('%d:%02d:%02d', hours, minutes, secs) :
                format('%02d:%02d', minutes, secs)
            end

            def elapsed_ms(started)
              ((clock - started) * 1000.0).round(3)
            end

            def clock
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end

            def summary_line(snapshot)
              live = snapshot['v3_box_proxy']
              comparison = snapshot['aggregate_decision_comparison']
              format(
                'elapsed %.3fs, proxy=%d, fallback=%d, statuses_match=%s, next_stage=%s',
                live['elapsed_ms'].to_f / 1000.0,
                live['proxy_pair_count'].to_i,
                live['fallback_pair_count'].to_i,
                comparison['status_counts_match'].inspect,
                snapshot['benchmark_passed_for_next_stage'].inspect
              )
            end

            def log(message)
              text = "[IndoorGML][V3BoxProxyBenchmark] #{message}"
              if defined?(IndoorCore::Logger) && IndoorCore::Logger.respond_to?(:puts)
                IndoorCore::Logger.puts(text)
              else
                puts(text)
              end
            rescue StandardError
              nil
            end
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityRecheckV3BoxProxyBenchmark.send(
  :log,
  'loaded: v3 native AABB proxy benchmark; baseline/v2 are frozen references only'
)
