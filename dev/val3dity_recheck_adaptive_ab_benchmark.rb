# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'

require_relative 'val3dity_recheck_snapshot_store'
require_relative '../indoor3d/validity/val3dity_full_intersection_rechecker'
require_relative '../indoor3d/validity/val3dity_overlap_geometry_rechecker'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Development-only A/B benchmark that isolates the performance effect of
        # face-count adaptive routing. Both pipelines use the same current V3
        # implementation and safety policy; only the adaptive direct-Full route
        # is bypassed for the baseline pipeline.
        module Val3dityRecheckAdaptiveAbBenchmark
          CLOCK = Process::CLOCK_MONOTONIC
          BASELINE_NAME = 'adaptive_off_clipped_mesh_v3'
          ADAPTIVE_NAME = 'adaptive_on_direct_full_for_simple'
          DIRECT_FULL_PATH =
            Val3dityClippedMeshRecheck::AdaptiveRouting::DIRECT_FULL_PATH
          FACE_BUCKETS = [
            ['1..30', 1, 30],
            ['31..75', 31, 75],
            ['76..150', 76, 150],
            ['151..225', 151, 225],
            ['226..300', 226, 300]
          ].freeze

          # Same current canonical rechecker, but skips only AdaptiveRouting's
          # model_solid_intersection_for_pair wrapper. This is an isolation A/B,
          # not a checkout or replay of the historical V3 commit.
          class AdaptiveOffRechecker < Val3dityOverlapGeometryRechecker
            private

            def model_solid_intersection_for_pair(
              group1, group2, cell_id1, cell_id2
            )
              cursor = self.method(__method__).super_method
              cursor = cursor.super_method while
                cursor &&
                cursor.owner == Val3dityClippedMeshRecheck::AdaptiveRouting

              expected = Val3dityClippedMeshRecheck::Rechecker
              unless cursor && cursor.owner == expected
                owner = cursor&.owner
                raise "Adaptive routing bypass target mismatch: #{owner.inspect}"
              end

              cursor.call(group1, group2, cell_id1, cell_id2)
            end
          end

          class << self
            attr_reader :last_result, :last_result_path, :last_progress_log_path

            def run_snapshot(
              name_or_path = nil,
              report_name: nil,
              indoor_model: nil,
              iterations: 1
            )
              iterations = iterations.to_i
              raise ArgumentError, 'iterations must be >= 1' if iterations < 1

              store = Val3dityRecheckSnapshotStore
              directory = store.resolve_directory(name_or_path)
              request_path = store.request_path(name_or_path)
              unless directory && request_path && File.file?(request_path)
                raise 'Persistent recheck snapshot was not found.'
              end

              requests = Val3dityRecheckOnlyRunner.requests_from_file(request_path)
              raise 'Recheck request list is empty.' if requests.empty?

              model_context = indoor_model || IndoorCore::IndoorModel.current
              unless model_context&.model == Sketchup.active_model
                raise 'IndoorModel.current is not bound to the active SketchUp model.'
              end

              selection = select_simple_requests!(requests, model_context)
              selected = selection.fetch('requests')
              raise 'No adaptive-routing-eligible requests were found.' if
                selected.empty?

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              output_directory = File.join(
                directory,
                'adaptive_ab_benchmark',
                stamp
              )
              FileUtils.mkdir_p(output_directory)
              name = sanitize(report_name || "adaptive_ab_#{stamp}")
              @last_result_path = File.join(output_directory, "#{name}.json")
              @last_progress_log_path = File.join(
                output_directory,
                'progress.jsonl'
              )

              iteration_rows = []
              File.open(@last_progress_log_path, 'w:UTF-8') do |io|
                io.sync = true
                write_progress(
                  io,
                  event: 'start',
                  source_request_count: requests.length,
                  selected_request_count: selected.length,
                  iterations: iterations
                )

                iterations.times do |iteration_index|
                  order = iteration_index.even? ?
                    [:adaptive_off, :adaptive_on] :
                    [:adaptive_on, :adaptive_off]
                  runs = {}
                  order.each do |kind|
                    runs[kind.to_s] = execute(
                      selected,
                      model_context,
                      kind,
                      output_directory,
                      io,
                      iteration_index
                    )
                  end

                  comparison = compare(
                    runs.fetch('adaptive_off').fetch('decisions'),
                    runs.fetch('adaptive_on').fetch('decisions')
                  )
                  performance = performance_breakdown(
                    runs.fetch('adaptive_off').fetch('decisions'),
                    runs.fetch('adaptive_on').fetch('decisions'),
                    runs.fetch('adaptive_off').fetch('elapsed_ms'),
                    runs.fetch('adaptive_on').fetch('elapsed_ms')
                  )
                  iteration = {
                    'iteration' => iteration_index + 1,
                    'execution_order' => order.map(&:to_s),
                    'adaptive_off' => runs.fetch('adaptive_off'),
                    'adaptive_on' => runs.fetch('adaptive_on'),
                    'comparison' => comparison,
                    'performance' => performance
                  }
                  iteration['pass'] = iteration_pass?(
                    iteration,
                    selected.length
                  )
                  iteration_rows << iteration
                  write_progress(
                    io,
                    event: 'iteration_finish',
                    iteration: iteration_index + 1,
                    pass: iteration['pass'],
                    performance: performance.fetch('total'),
                    comparison: comparison
                  )
                end
              end

              aggregate = aggregate_iterations(iteration_rows)
              final_pass =
                selection.dig('preflight', 'valid') == true &&
                iteration_rows.all? { |row| row['pass'] == true }
              result = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'mode' => 'current_v3_adaptive_routing_off_vs_on',
                'ab_isolation' =>
                  'same current V3 code and safety policy; adaptive routing only',
                'historical_v3_commit_replayed' => false,
                'production_decision_modified' => false,
                'validation_report_modified' => false,
                'source_snapshot_directory' => directory,
                'request_path' => request_path,
                'request_sha256' => Digest::SHA256.file(request_path).hexdigest,
                'source_request_count' => requests.length,
                'adaptive_threshold_face_count' => adaptive_threshold,
                'adaptive_threshold_operator' => '<=',
                'iterations' => iterations,
                'selection' => selection.reject { |key, _| key == 'requests' },
                'selected_request_count' => selected.length,
                'iterations_data' => iteration_rows,
                'aggregate' => aggregate,
                'completed' => iteration_rows.length == iterations,
                'final_pass' => final_pass
              }
              File.write(
                @last_result_path,
                JSON.pretty_generate(result),
                encoding: 'UTF-8'
              )
              File.open(@last_progress_log_path, 'a:UTF-8') do |io|
                write_progress(
                  io,
                  event: 'finish',
                  final_pass: final_pass,
                  aggregate: aggregate
                )
              end
              @last_result = result
            end

            def print_report(result = @last_result)
              raise 'No adaptive A/B benchmark result is available.' unless result

              selection = result.fetch('selection')
              aggregate = result.fetch('aggregate')
              total = aggregate.fetch('total')
              puts
              puts('=' * 122)
              puts('CURRENT V3 ADAPTIVE ROUTING A/B — OFF(CLIPPED MESH) vs ON(DIRECT FULL)')
              puts('=' * 122)
              puts "source_request_count        : #{result['source_request_count']}"
              puts "selected_request_count      : #{result['selected_request_count']}"
              puts "threshold                   : max(face_count) <= #{result['adaptive_threshold_face_count']}"
              puts "resolved_unique_cell_count  : #{selection.dig('preflight', 'resolved_unique_cell_count')}"
              puts "unresolved_unique_cell_count: #{selection.dig('preflight', 'unresolved_unique_cell_count')}"
              puts "iterations                  : #{result['iterations']}"
              puts "historical_commit_replayed  : #{result['historical_v3_commit_replayed']}"
              puts('-' * 122)

              result.fetch('iterations_data').each do |iteration|
                off = iteration.fetch('adaptive_off')
                on = iteration.fetch('adaptive_on')
                perf = iteration.dig('performance', 'total')
                cmp = iteration.fetch('comparison')
                puts "iteration #{iteration['iteration']} order=#{iteration['execution_order'].join(' -> ')}"
                puts format(
                  '  adaptive OFF=%10.3f ms  adaptive ON=%10.3f ms  speedup=%7.3fx  reduction=%7.3f%%',
                  off['elapsed_ms'],
                  on['elapsed_ms'],
                  perf['speedup_adaptive_on_vs_off'],
                  perf['reduction_percent']
                )
                puts "  OFF paths=#{off['path_counts']}"
                puts "  ON  paths=#{on['path_counts']}"
                puts "  transitions=#{cmp['transition_counts']}"
                puts "  mismatches: status=#{cmp['status_mismatch_count']} tolerated=#{cmp['tolerated_mismatch_count']} volume=#{cmp['kept_volume_mismatch_count']} components=#{cmp['kept_component_mismatch_count']}"
                puts "  errors: OFF=#{off['errors'].length} ON=#{on['errors'].length} path_violations: OFF=#{off['path_violation_count']} ON=#{on['path_violation_count']} PASS=#{iteration['pass']}"
              end

              puts('-' * 122)
              puts format(
                'aggregate OFF=%10.3f ms  ON=%10.3f ms  speedup=%7.3fx  reduction=%7.3f%%',
                total['adaptive_off_elapsed_ms'],
                total['adaptive_on_elapsed_ms'],
                total['speedup_adaptive_on_vs_off'],
                total['reduction_percent']
              )
              puts format(
                'pair median OFF=%8.3f ms  ON=%8.3f ms  speedup=%7.3fx',
                total['adaptive_off_pair_median_ms'],
                total['adaptive_on_pair_median_ms'],
                total['pair_median_speedup']
              )
              puts('-' * 122)
              puts('BY FINAL STATUS')
              aggregate.fetch('by_status').each do |status, row|
                puts format_group(status, row)
              end
              puts('-' * 122)
              puts('BY MAX FACE COUNT')
              aggregate.fetch('by_face_bucket').each do |bucket, row|
                puts format_group(bucket, row)
              end
              puts('-' * 122)
              puts "completed                    : #{result['completed']}"
              puts "FINAL PASS                   : #{result['final_pass']}"
              puts "result_path                  : #{@last_result_path}"
              puts "progress_path                : #{@last_progress_log_path}"
              puts('=' * 122)
              result
            end

            private

            def adaptive_threshold
              Val3dityClippedMeshRecheck.simple_solid_face_threshold.to_i
            end

            def select_simple_requests!(requests, indoor_model)
              checker = Val3dityFullIntersectionRechecker.new(
                indoor_model: indoor_model,
                model: indoor_model.model,
                tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
                logger: nil
              )
              cell_ids = requests.flat_map do |request|
                Array(request['cells']).first(2).map(&:to_s)
              end.reject(&:empty?).uniq.sort
              cache = {}
              failures = []

              cell_ids.each do |cell_id|
                geometry = checker.send(:model_cell_geometry, cell_id)
                status = geometry[:status].to_s
                if status == 'ok'
                  cache[cell_id] = Array(geometry[:faces]).length
                else
                  failures << {
                    'cell_id' => cell_id,
                    'status' => status,
                    'reason' => geometry[:reason]&.to_s
                  }
                end
              rescue StandardError => e
                failures << {
                  'cell_id' => cell_id,
                  'status' => 'error',
                  'reason' => "#{e.class}: #{e.message}"
                }
              end

              preflight = {
                'requested_unique_cell_count' => cell_ids.length,
                'resolved_unique_cell_count' => cell_ids.length - failures.length,
                'unresolved_unique_cell_count' => failures.length,
                'failure_samples' => failures.first(20),
                'valid' => failures.empty?
              }
              unless failures.empty?
                details = failures.first(10).map do |row|
                  "  #{row['cell_id']}: #{row['reason']}"
                end.join("\n")
                raise RuntimeError,
                      "Snapshot does not match the current IndoorModel.\n" \
                      "resolved=#{preflight['resolved_unique_cell_count']} / " \
                      "#{preflight['requested_unique_cell_count']} unique CellSpaces\n" \
                      "#{details}"
              end

              threshold = adaptive_threshold
              selected = []
              nonpositive_count = 0
              requests.each_with_index do |request, source_index|
                cells = Array(request['cells']).first(2).map(&:to_s)
                face_counts = cells.map { |cell_id| cache.fetch(cell_id) }
                if face_counts.any? { |count| count <= 0 }
                  nonpositive_count += 1
                  next
                end
                next unless face_counts.max <= threshold

                selected << {
                  'source_index' => source_index,
                  'code' => request['code'],
                  'cells' => cells,
                  'face_counts' => face_counts,
                  'max_face_count' => face_counts.max
                }
              end

              {
                'preflight' => preflight,
                'threshold_face_count' => threshold,
                'source_request_count' => requests.length,
                'selected_request_count' => selected.length,
                'excluded_request_count' => requests.length - selected.length,
                'nonpositive_face_count_request_count' => nonpositive_count,
                'selected_status_unknown_until_run' => true,
                'selected_face_bucket_counts' => selected.map do |row|
                  face_bucket(row['max_face_count'])
                end.tally.sort.to_h,
                'requests' => selected
              }
            end

            def execute(
              requests,
              model,
              kind,
              output_directory,
              io,
              iteration_index
            )
              pipeline_name = kind == :adaptive_off ? BASELINE_NAME : ADAPTIVE_NAME
              runner = Val3dityRunner.new(
                File.join(
                  output_directory,
                  "__#{pipeline_name}_#{iteration_index + 1}.gml"
                ),
                report_name: "#{pipeline_name}_#{iteration_index + 1}",
                work_dir: output_directory,
                indoor_model: model
              )
              checker_class = kind == :adaptive_off ?
                AdaptiveOffRechecker : Val3dityOverlapGeometryRechecker
              checker = checker_class.new(
                indoor_model: model,
                model: model.model,
                tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
                logger: nil
              )
              runner.instance_variable_set(:@overlap_geometry_rechecker, checker)

              started = clock
              rows = []
              errors = []
              counts = Hash.new(0)
              path_violations = []
              requests.each_with_index do |request, local_index|
                pair_started = clock
                result = runner.send(
                  :recheck_cell_pair,
                  request['code'],
                  request['cells'][0],
                  request['cells'][1]
                )
                record = checker.proxy_record(*request['cells'])
                path = record.is_a?(Hash) ? record['path'].to_s : ''
                row = {
                  'iteration' => iteration_index + 1,
                  'local_index' => local_index,
                  'source_index' => request['source_index'],
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'face_counts' => request['face_counts'],
                  'max_face_count' => request['max_face_count'],
                  'status' => value(result, 'status').to_s,
                  'tolerated' => value(result, 'tolerated'),
                  'reason' => value(result, 'reason').to_s,
                  'volume_mm3' => value(
                    result,
                    'actual_overlap_volume_mm3'
                  ),
                  'component_count' => value(
                    result,
                    'intersection_component_count'
                  ),
                  'elapsed_ms' => elapsed(pair_started),
                  'recheck_path' => record,
                  'path' => path
                }
                violation = if kind == :adaptive_off
                              path == DIRECT_FULL_PATH
                            else
                              path != DIRECT_FULL_PATH
                            end
                if violation
                  path_violations << {
                    'source_index' => request['source_index'],
                    'cells' => request['cells'],
                    'path' => path
                  }
                end
                rows << row
                counts[row['status']] += 1
                write_progress(
                  io,
                  event: 'pair',
                  iteration: iteration_index + 1,
                  pipeline: kind.to_s,
                  local_index: local_index,
                  source_index: request['source_index'],
                  status: row['status'],
                  path: path,
                  elapsed_ms: row['elapsed_ms']
                )
              rescue StandardError => e
                counts['error'] += 1
                errors << {
                  'iteration' => iteration_index + 1,
                  'local_index' => local_index,
                  'source_index' => request['source_index'],
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'error' => "#{e.class}: #{e.message}"
                }
              end

              {
                'pipeline' => pipeline_name,
                'elapsed_ms' => elapsed(started),
                'processed_request_count' => rows.length + errors.length,
                'status_counts' => counts.sort.to_h,
                'path_counts' => rows.map do |row|
                  row['path'].empty? ? 'missing' : row['path']
                end.tally.sort.to_h,
                'path_violation_count' => path_violations.length,
                'path_violations' => path_violations.first(50),
                'mesh_cache_entry_count' => checker.respond_to?(:mesh_cache) ?
                  checker.mesh_cache.length : nil,
                'decisions' => rows,
                'errors' => errors
              }
            end

            def compare(adaptive_off, adaptive_on)
              by_index = adaptive_on.to_h do |row|
                [row['source_index'], row]
              end
              transitions = Hash.new(0)
              missing = []
              identity = []
              status = []
              tolerated = []
              volumes = []
              components = []

              adaptive_off.each do |base|
                live = by_index[base['source_index']]
                unless live
                  missing << base
                  next
                end
                unless base.values_at('code', 'cells') ==
                       live.values_at('code', 'cells')
                  identity << [base, live]
                  next
                end

                transitions["#{base['status']}->#{live['status']}"] += 1
                status << [base, live] unless base['status'] == live['status']
                tolerated << [base, live] unless
                  base['tolerated'] == live['tolerated']
                next unless base['status'] == 'kept' && live['status'] == 'kept'

                volumes << [base, live] unless same_volume?(
                  base['volume_mm3'], live['volume_mm3']
                )
                base_components = base['component_count'].to_i
                live_components = live['component_count'].to_i
                components << [base, live] unless
                  base_components.positive? &&
                  live_components.positive? &&
                  base_components == live_components
              end

              {
                'pair_count_match' => adaptive_off.length == adaptive_on.length,
                'transition_counts' => transitions.sort.to_h,
                'missing_pair_count' => missing.length,
                'identity_mismatch_count' => identity.length,
                'status_mismatch_count' => status.length,
                'tolerated_mismatch_count' => tolerated.length,
                'kept_volume_mismatch_count' => volumes.length,
                'kept_component_mismatch_count' => components.length,
                'missing_pairs' => missing.first(50),
                'identity_mismatches' => identity.first(50),
                'status_mismatches' => status.first(50),
                'tolerated_mismatches' => tolerated.first(50),
                'kept_volume_mismatches' => volumes.first(50),
                'kept_component_mismatches' => components.first(50)
              }
            end

            def performance_breakdown(
              adaptive_off,
              adaptive_on,
              adaptive_off_elapsed,
              adaptive_on_elapsed
            )
              {
                'total' => performance_row(
                  adaptive_off,
                  adaptive_on,
                  adaptive_off_elapsed,
                  adaptive_on_elapsed
                ),
                'by_status' => grouped_performance(
                  adaptive_off,
                  adaptive_on
                ) { |row| row['status'] },
                'by_face_bucket' => grouped_performance(
                  adaptive_off,
                  adaptive_on
                ) { |row| face_bucket(row['max_face_count']) }
              }
            end

            def grouped_performance(adaptive_off, adaptive_on)
              live_by_index = adaptive_on.to_h do |row|
                [[row['iteration'], row['source_index']], row]
              end
              grouped = Hash.new { |hash, key| hash[key] = [[], []] }
              adaptive_off.each do |base|
                live = live_by_index[[base['iteration'], base['source_index']]]
                next unless live

                key = yield(base)
                grouped[key][0] << base
                grouped[key][1] << live
              end
              grouped.sort.to_h.transform_values do |off_rows, on_rows|
                performance_row(off_rows, on_rows)
              end
            end

            def performance_row(
              adaptive_off,
              adaptive_on,
              adaptive_off_elapsed = nil,
              adaptive_on_elapsed = nil
            )
              off_samples = adaptive_off.map { |row| row['elapsed_ms'].to_f }
              on_samples = adaptive_on.map { |row| row['elapsed_ms'].to_f }
              off_total = adaptive_off_elapsed || off_samples.sum
              on_total = adaptive_on_elapsed || on_samples.sum
              speedup = on_total.to_f.positive? ?
                off_total.to_f / on_total.to_f : 0.0
              off_median = median(off_samples)
              on_median = median(on_samples)
              {
                'pair_count' => [adaptive_off.length, adaptive_on.length].min,
                'adaptive_off_elapsed_ms' => off_total.to_f.round(3),
                'adaptive_on_elapsed_ms' => on_total.to_f.round(3),
                'speedup_adaptive_on_vs_off' => speedup.round(4),
                'reduction_percent' => off_total.to_f.positive? ?
                  (((off_total.to_f - on_total.to_f) / off_total.to_f) * 100.0).round(3) : nil,
                'adaptive_off_pair_median_ms' => off_median.round(6),
                'adaptive_on_pair_median_ms' => on_median.round(6),
                'pair_median_speedup' => on_median.positive? ?
                  (off_median / on_median).round(4) : 0.0
              }
            end

            def aggregate_iterations(iterations)
              off_rows = iterations.flat_map do |row|
                row.dig('adaptive_off', 'decisions')
              end
              on_rows = iterations.flat_map do |row|
                row.dig('adaptive_on', 'decisions')
              end
              off_elapsed = iterations.sum do |row|
                row.dig('adaptive_off', 'elapsed_ms').to_f
              end
              on_elapsed = iterations.sum do |row|
                row.dig('adaptive_on', 'elapsed_ms').to_f
              end
              performance_breakdown(
                off_rows,
                on_rows,
                off_elapsed,
                on_elapsed
              )
            end

            def iteration_pass?(iteration, expected_count)
              off = iteration.fetch('adaptive_off')
              on = iteration.fetch('adaptive_on')
              comparison = iteration.fetch('comparison')
              off['processed_request_count'].to_i == expected_count &&
                on['processed_request_count'].to_i == expected_count &&
                Array(off['errors']).empty? &&
                Array(on['errors']).empty? &&
                off['path_violation_count'].to_i.zero? &&
                on['path_violation_count'].to_i.zero? &&
                comparison['pair_count_match'] == true &&
                %w[
                  missing_pair_count
                  identity_mismatch_count
                  status_mismatch_count
                  tolerated_mismatch_count
                  kept_volume_mismatch_count
                  kept_component_mismatch_count
                ].all? { |key| comparison[key].to_i.zero? }
            end

            def face_bucket(value)
              count = value.to_i
              row = FACE_BUCKETS.find do |_name, minimum, maximum|
                count >= minimum && count <= maximum
              end
              row ? row.first : "#{count}"
            end

            def same_volume?(left, right)
              return false unless positive_finite?(left) && positive_finite?(right)

              tolerance = [left.to_f.abs, right.to_f.abs, 1.0].max * 1.0e-6
              (left.to_f - right.to_f).abs <= tolerance
            end

            def positive_finite?(value)
              number = Float(value)
              number.finite? && number.positive?
            rescue ArgumentError, TypeError
              false
            end

            def median(values)
              sorted = Array(values).map(&:to_f).sort
              return 0.0 if sorted.empty?

              middle = sorted.length / 2
              return sorted[middle] if sorted.length.odd?

              (sorted[middle - 1] + sorted[middle]) / 2.0
            end

            def format_group(name, row)
              format(
                '%-18s pairs=%5d OFF=%10.3fms ON=%10.3fms speedup=%7.3fx reduction=%7.3f%%',
                name,
                row['pair_count'],
                row['adaptive_off_elapsed_ms'],
                row['adaptive_on_elapsed_ms'],
                row['speedup_adaptive_on_vs_off'],
                row['reduction_percent']
              )
            end

            def value(hash, key)
              return hash[key] if hash.key?(key)

              symbol = key.to_sym
              hash.key?(symbol) ? hash[symbol] : nil
            end

            def sanitize(value)
              value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
            end

            def write_progress(io, payload)
              io.write(JSON.generate(payload))
              io.write("\n")
              io.flush
            end

            def elapsed(started)
              ((clock - started) * 1000.0).round(3)
            end

            def clock
              Process.clock_gettime(CLOCK)
            end
          end
        end
      end
    end
  end
end
