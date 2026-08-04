# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

require_relative 'val3dity_recheck_snapshot_store'
require_relative 'val3dity_recheck_clipped_operand_probe_v2'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only recheck timing comparison.
        #
        # Baseline runs the existing recheck for every captured request.
        # Hybrid runs the v2 topology gate for every unique pair and falls back
        # to the existing recheck only for open/error/surface-miss pairs.
        #
        # v2 does not yet build a capped proxy or calculate final 701/704
        # decisions. Therefore hybrid elapsed time is a lower bound only.
        module Val3dityRecheckV2FallbackTiming
          SCHEMA_VERSION = 1
          DEFAULT_LOG_INTERVAL = 25

          class << self
            attr_reader :last_result_path, :last_snapshot

            def compare_snapshot(name_or_path = nil, report_name: nil,
                                 output_dir: nil,
                                 console_interval: DEFAULT_LOG_INTERVAL,
                                 indoor_model: nil)
              store = Val3dityRecheckSnapshotStore
              snapshot_dir = store.resolve_directory(name_or_path)
              request_path = store.request_path(name_or_path)
              raise 'Persistent recheck snapshot was not found.' unless
                snapshot_dir && request_path && File.file?(request_path)

              requests = Val3dityRecheckOnlyRunner.requests_from_file(request_path)
              raise 'Recheck request list is empty.' if requests.empty?

              indoor_model ||= IndoorCore::IndoorModel.current
              raise 'IndoorModel.current is not bound to the active model.' unless
                indoor_model&.model == Sketchup.active_model

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              name = sanitize(report_name || "v2_fallback_comparison_#{stamp}")
              directory = File.expand_path(
                output_dir || File.join(snapshot_dir, 'comparisons', stamp)
              )
              FileUtils.mkdir_p(directory)

              log("start requests=#{requests.length}, snapshot=#{snapshot_dir}")
              baseline = run_baseline(
                requests, indoor_model, directory, "#{name}_baseline",
                console_interval
              )
              GC.start
              hybrid = run_hybrid(
                requests, indoor_model, directory, "#{name}_hybrid",
                console_interval
              )

              baseline_ms = baseline['elapsed_ms'].to_f
              hybrid_ms = hybrid['elapsed_ms'].to_f
              snapshot = {
                'schema_version' => SCHEMA_VERSION,
                'generated_at' => Time.now.iso8601(6),
                'mode' => 'recheck_only_v2_fallback_timing',
                'gml_export_skipped' => true,
                'val3dity_skipped' => true,
                'production_code_modified' => false,
                'execution_order' => ['baseline', 'v2_gate_plus_fallback'],
                'source_snapshot_directory' => snapshot_dir,
                'request_path' => request_path,
                'request_count' => requests.length,
                'unique_pair_count' => unique_pair_count(requests),
                'baseline' => baseline,
                'v2_gate_plus_fallback' => hybrid,
                'comparison' => comparison(baseline_ms, hybrid_ms)
              }

              path = File.join(directory, "#{name}.json")
              File.write(path, JSON.pretty_generate(snapshot), encoding: 'UTF-8')
              @last_snapshot = snapshot
              @last_result_path = path
              log("saved #{path}")
              log(format('baseline %.3fs, hybrid floor %.3fs, upper bound %.2fx',
                         baseline_ms / 1000.0, hybrid_ms / 1000.0,
                         ratio(baseline_ms, hybrid_ms).to_f))
              snapshot
            ensure
              set_status('')
            end

            private

            def run_baseline(requests, indoor_model, directory, name, interval)
              runner = new_runner(indoor_model, directory, name)
              started = clock
              statuses = Hash.new(0)
              errors = []

              requests.each_with_index do |request, index|
                result = runner.send(:recheck_cell_pair, request['code'],
                                     request['cells'][0], request['cells'][1])
                statuses[(result['status'] || result[:status] || 'unknown').to_s] += 1
                progress('baseline', index, requests.length, request, started, interval)
              rescue StandardError => e
                statuses['error'] += 1
                errors << error_row(request, index, e)
                progress('baseline', index, requests.length, request, started,
                         interval, force: true)
              end

              {
                'mode' => 'original_full_recheck',
                'production_equivalent_pair_decisions' => true,
                'elapsed_ms' => elapsed_ms(started),
                'request_count' => requests.length,
                'unique_pair_count' => unique_pair_count(requests),
                'status_counts' => statuses.sort.to_h,
                'errors' => errors
              }
            end

            def run_hybrid(requests, indoor_model, directory, name, interval)
              runner = new_runner(indoor_model, directory, name)
              analyzer = Val3dityRecheckClippedOperandProbe::Analyzer.new(
                Utils::Geometry::VALIDATION_TOLERANCE
              )
              cell_index = build_cell_index(indoor_model)
              mesh_cache = {}
              pair_cache = {}
              fallback_statuses = Hash.new(0)
              errors = []
              started = clock

              requests.each_with_index do |request, index|
                key = pair_key(request['cells'])
                pair_cache[key] ||= analyze_pair(
                  analyzer, request['cells'], cell_index, mesh_cache
                )
                pair = pair_cache[key]

                unless pair['v2_topology_success']
                  result = runner.send(:recheck_cell_pair, request['code'],
                                       request['cells'][0], request['cells'][1])
                  status = result['status'] || result[:status] || 'unknown'
                  fallback_statuses[status.to_s] += 1
                end
                progress('hybrid', index, requests.length, request, started, interval)
              rescue StandardError => e
                errors << error_row(request, index, e)
                progress('hybrid', index, requests.length, request, started,
                         interval, force: true)
              end

              pairs = pair_cache.values
              fallback_pairs = pairs.reject { |row| row['v2_topology_success'] }
              {
                'mode' => 'v2_topology_gate_plus_original_fallback',
                'production_equivalent_pair_decisions' => false,
                'timing_interpretation' => 'lower_bound_only',
                'elapsed_ms' => elapsed_ms(started),
                'request_count' => requests.length,
                'unique_pair_count' => pairs.length,
                'v2_topology_success_pair_count' =>
                  pairs.count { |row| row['v2_topology_success'] },
                'fallback_pair_count' => fallback_pairs.length,
                'fallback_request_count' => requests.count do |request|
                  !pair_cache.fetch(pair_key(request['cells']))['v2_topology_success']
                end,
                'fallback_reason_counts' =>
                  fallback_pairs.map { |row| row['fallback_reason'] }.tally.sort.to_h,
                'fallback_status_counts' => fallback_statuses.sort.to_h,
                'mesh_cache_entry_count' => mesh_cache.length,
                'pairs' => pairs,
                'errors' => errors
              }
            end

            def analyze_pair(analyzer, cells, index, mesh_cache)
              started = clock
              cell1 = index[cells[0].to_s]
              cell2 = index[cells[1].to_s]
              return failed_pair(cells, 'cellspace_not_found', started) unless cell1 && cell2

              group1 = valid_group(cell1)
              group2 = valid_group(cell2)
              return failed_pair(cells, 'cellspace_group_invalid', started) unless group1 && group2

              analysis = analyzer.analyze(group1, group2, cells, mesh_cache)
              reason = if analysis['status'] != 'ok'
                         'v2_analysis_error'
                       elsif analysis['surface_miss_requires_containment_test'] == true
                         'surface_miss'
                       elsif analysis['global_cap_graph_closed'] != true
                         'global_cap_open'
                       end
              {
                'cells' => cells,
                'v2_topology_success' => reason.nil?,
                'fallback_reason' => reason,
                'gate_elapsed_ms' => elapsed_ms(started),
                'analysis' => analysis
              }
            rescue StandardError => e
              failed_pair(cells, 'v2_analysis_exception', started,
                          "#{e.class}: #{e.message}")
            end

            def failed_pair(cells, reason, started, error = nil)
              {
                'cells' => cells,
                'v2_topology_success' => false,
                'fallback_reason' => reason,
                'gate_elapsed_ms' => elapsed_ms(started),
                'analysis' => { 'status' => 'error', 'error' => error || reason }
              }
            end

            def build_cell_index(indoor_model)
              cells = Array(indoor_model&.cell_spaces)
              index = {}
              cells.each do |cell|
                id = cell&.id.to_s
                index[id] = cell unless id.empty?
              end

              used = {}
              cells.each do |cell|
                id = cell&.id.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
                id = 'missing' if id.empty?
                base = "cell_#{id}"
                report_id = base
                suffix = 2
                while used[report_id]
                  report_id = "#{base}_#{suffix}"
                  suffix += 1
                end
                used[report_id] = true
                index[report_id] = cell
              end
              index
            end

            def valid_group(cell)
              group = cell.respond_to?(:valid_sketchup_group) ?
                cell.valid_sketchup_group : cell.sketchup_group
              group if group&.valid?
            rescue StandardError
              nil
            end

            def new_runner(indoor_model, directory, name)
              Val3dityRunner.new(
                File.join(directory, '__recheck_only_input__.gml'),
                report_name: name,
                work_dir: directory,
                indoor_model: indoor_model
              )
            end

            def comparison(baseline_ms, hybrid_ms)
              {
                'baseline_elapsed_ms' => baseline_ms.round(3),
                'hybrid_gate_plus_fallback_elapsed_ms' => hybrid_ms.round(3),
                'measured_time_reduction_ms' => (baseline_ms - hybrid_ms).round(3),
                'measured_time_reduction_percent' =>
                  baseline_ms.positive? ?
                    (((baseline_ms - hybrid_ms) / baseline_ms) * 100.0).round(3) : 0.0,
                'measured_speedup_upper_bound' => ratio(baseline_ms, hybrid_ms),
                'interpretation' => 'timing_lower_bound_only',
                'missing_from_hybrid_measurement' => [
                  'closed-pair shared-face candidate analysis',
                  'closed-pair proxy solid construction',
                  'closed-pair proxy manifold validation',
                  'closed-pair proxy Boolean intersection',
                  'closed-pair final 701/704 decision'
                ]
              }
            end

            def progress(phase, index, total, request, started, interval, force: false)
              current = index + 1
              percent = total.zero? ? 100.0 : current.to_f / total * 100.0
              elapsed = clock - started
              eta = current.positive? ? elapsed / current * (total - current) : nil
              message = format(
                '[RecheckCompare][%s] %d/%d %.1f%% code=%d %s <-> %s elapsed=%s eta=%s',
                phase, current, total, percent, request['code'],
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

            def unique_pair_count(requests)
              requests.map { |row| pair_key(row['cells']) }.uniq.length
            end

            def pair_key(cells)
              Array(cells).map(&:to_s).sort.join('|')
            end

            def ratio(a, b)
              b.positive? ? (a / b).round(3) : nil
            end

            def sanitize(value)
              text = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              text.empty? ? 'v2_fallback_comparison' : text
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

            def log(message)
              text = "[IndoorGML][V2FallbackTiming] #{message}"
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

ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityRecheckV2FallbackTiming.send(
  :log,
  'loaded: original recheck versus v2 topology gate + original fallback'
)
