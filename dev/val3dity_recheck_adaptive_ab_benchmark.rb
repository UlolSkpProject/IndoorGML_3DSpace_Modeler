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
        # face-count adaptive routing. Both pipelines use the same current
        # clipped-mesh implementation and safety policy; only the adaptive
        # direct-Full route is bypassed for the baseline pipeline.
        module Val3dityRecheckAdaptiveAbBenchmark
          CLOCK = Process::CLOCK_MONOTONIC
          BASELINE_NAME = 'adaptive_off_clipped_mesh'
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
          # not a checkout or replay of a historical baseline commit.
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
              selection = select_simple_requests(requests, model_context)
              selected = selection.fetch('requests')
              raise 'No simple-solid requests matched the adaptive threshold.' if selected.empty?

              output_directory = benchmark_output_directory(
                directory,
                report_name
              )
              FileUtils.mkdir_p(output_directory)
              progress_path = File.join(output_directory, 'progress.jsonl')
              result_path = File.join(output_directory, 'result.json')

              iteration_rows = []
              File.open(progress_path, 'wb') do |io|
                write_progress(
                  io,
                  event: 'benchmark_start',
                  snapshot: directory,
                  source_request_count: requests.length,
                  selected_request_count: selected.length,
                  adaptive_threshold_face_count: adaptive_threshold,
                  iterations: iterations
                )

                iterations.times do |iteration_index|
                  order = iteration_index.even? ? %i[adaptive_off adaptive_on] :
                    %i[adaptive_on adaptive_off]
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
                'mode' => 'clipped_mesh_adaptive_routing_off_vs_on',
                'ab_isolation' =>
                  'same current clipped-mesh implementation and safety policy; ' \
                  'adaptive routing only',
                'historical_baseline_commit_replayed' => false,
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

              File.write(result_path, JSON.pretty_generate(result))
              @last_result = result
              @last_result_path = result_path
              @last_progress_log_path = progress_path
              result
            rescue StandardError => error
              failure = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'completed' => false,
                'final_pass' => false,
                'error_class' => error.class.name,
                'error_message' => error.message,
                'backtrace' => Array(error.backtrace)
              }
              @last_result = failure
              raise
            end

            def print_report(result = @last_result)
              raise 'No benchmark result is available.' unless result

              puts '=== VAL3DITY RECHECK ADAPTIVE A/B ==='
              puts "source_request_count=#{result['source_request_count']}"
              puts "selected_request_count=#{result['selected_request_count']}"
              puts "threshold=#{result['adaptive_threshold_operator']} " \
                   "#{result['adaptive_threshold_face_count']} faces"
              Array(result['iterations_data']).each do |iteration|
                puts "-- ITERATION #{iteration['iteration']} --"
                puts "execution_order=#{iteration['execution_order'].join(' -> ')}"
                print_run_summary('OFF', iteration.fetch('adaptive_off'))
                print_run_summary('ON ', iteration.fetch('adaptive_on'))
                print_comparison(iteration.fetch('comparison'))
                print_performance(iteration.fetch('performance'))
                puts "iteration_pass=#{iteration['pass']}"
              end
              print_aggregate(result['aggregate'])
              puts "FINAL PASS=#{result['final_pass']}"
              puts "result_path=#{@last_result_path}" if @last_result_path
              puts "progress_path=#{@last_progress_log_path}" if
                @last_progress_log_path
              result
            end

            private

            def adaptive_threshold
              Val3dityClippedMeshRecheck::AdaptiveRouting::
                SIMPLE_SOLID_FACE_THRESHOLD
            end

            def select_simple_requests(requests, indoor_model)
              cache = {}
              unresolved = []
              stale = []
              selected = []
              skipped = []

              requests.each_with_index do |request, index|
                cell_ids = request_cell_ids(request)
                groups = cell_ids.map do |cell_id|
                  resolve_cell_group(cell_id, indoor_model, cache)
                end
                if groups.any?(&:nil?)
                  unresolved << {
                    'source_index' => index,
                    'cell_ids' => cell_ids
                  }
                  next
                end
                unless groups.all? { |group| entity_alive?(group) }
                  stale << {
                    'source_index' => index,
                    'cell_ids' => cell_ids
                  }
                  next
                end

                face_counts = groups.map { |group| face_count(group) }
                max_face_count = face_counts.max.to_i
                annotated = deep_dup(request)
                annotated['_benchmark_source_index'] = index
                annotated['_benchmark_face_counts'] = face_counts
                annotated['_benchmark_max_face_count'] = max_face_count
                annotated['_benchmark_face_bucket'] = face_bucket(max_face_count)

                if max_face_count <= adaptive_threshold
                  selected << annotated
                else
                  skipped << {
                    'source_index' => index,
                    'cell_ids' => cell_ids,
                    'face_counts' => face_counts,
                    'max_face_count' => max_face_count
                  }
                end
              end

              valid = unresolved.empty? && stale.empty?
              {
                'preflight' => {
                  'valid' => valid,
                  'unresolved_count' => unresolved.length,
                  'stale_count' => stale.length,
                  'unresolved' => unresolved,
                  'stale' => stale
                },
                'selected_count' => selected.length,
                'skipped_complex_count' => skipped.length,
                'skipped_complex' => skipped,
                'requests' => selected
              }.tap do |selection|
                unless valid
                  raise 'Snapshot preflight failed: unresolved or stale CellSpaces.'
                end
              end
            end

            def execute(
              selected,
              indoor_model,
              kind,
              output_directory,
              progress_io,
              iteration_index
            )
              runner_class = kind == :adaptive_off ?
                AdaptiveOffRechecker : Val3dityOverlapGeometryRechecker
              runner = runner_class.new(indoor_model)
              label = kind == :adaptive_off ? BASELINE_NAME : ADAPTIVE_NAME
              run_directory = File.join(
                output_directory,
                format('iteration_%02d', iteration_index + 1),
                label
              )
              FileUtils.mkdir_p(run_directory)
              write_progress(
                progress_io,
                event: 'run_start',
                iteration: iteration_index + 1,
                kind: kind,
                label: label,
                request_count: selected.length
              )

              started = Process.clock_gettime(CLOCK)
              decisions = []
              selected.each_with_index do |request, run_index|
                decision = runner.recheck(request, workspace: run_directory)
                decisions << annotate_decision(decision, request, run_index)
                write_progress(
                  progress_io,
                  event: 'request_finish',
                  iteration: iteration_index + 1,
                  kind: kind,
                  run_index: run_index,
                  source_index: request['_benchmark_source_index'],
                  path: decision_value(decision, 'path'),
                  final_status: decision_value(decision, 'status'),
                  elapsed_ms: decision_value(decision, 'elapsed_ms')
                )
              rescue StandardError => error
                decisions << error_decision(request, run_index, error)
                write_progress(
                  progress_io,
                  event: 'request_error',
                  iteration: iteration_index + 1,
                  kind: kind,
                  run_index: run_index,
                  source_index: request['_benchmark_source_index'],
                  error_class: error.class.name,
                  error_message: error.message
                )
              end
              elapsed_ms = elapsed_since(started)
              path_counts = tally(decisions) { |row| row['path'].to_s }
              status_counts = tally(decisions) { |row| row['final_status'].to_s }
              error_count = decisions.count { |row| row['error'] }
              path_violation_count = decisions.count do |row|
                path_violation?(kind, row['path'])
              end

              payload = {
                'name' => label,
                'kind' => kind.to_s,
                'elapsed_ms' => elapsed_ms,
                'request_count' => selected.length,
                'decision_count' => decisions.length,
                'status_counts' => status_counts,
                'path_counts' => path_counts,
                'error_count' => error_count,
                'path_violation_count' => path_violation_count,
                'decisions' => decisions
              }
              write_progress(
                progress_io,
                event: 'run_finish',
                iteration: iteration_index + 1,
                kind: kind,
                elapsed_ms: elapsed_ms,
                error_count: error_count,
                path_violation_count: path_violation_count,
                path_counts: path_counts,
                status_counts: status_counts
              )
              payload
            end

            def annotate_decision(decision, request, run_index)
              normalized = normalize_hash(decision)
              {
                'run_index' => run_index,
                'source_index' => request['_benchmark_source_index'],
                'cell_ids' => request_cell_ids(request),
                'face_counts' => request['_benchmark_face_counts'],
                'max_face_count' => request['_benchmark_max_face_count'],
                'face_bucket' => request['_benchmark_face_bucket'],
                'path' => decision_value(normalized, 'path'),
                'final_status' => decision_value(normalized, 'status'),
                'tolerated' => truthy_or_false(
                  decision_value(normalized, 'tolerated')
                ),
                'actual_overlap_volume_mm3' => numeric_or_nil(
                  decision_value(normalized, 'actual_overlap_volume_mm3')
                ),
                'component_count' => integer_or_nil(
                  decision_value(normalized, 'component_count')
                ),
                'elapsed_ms' => numeric_or_nil(
                  decision_value(normalized, 'elapsed_ms')
                ),
                'error' => false,
                'decision' => normalized
              }
            end

            def error_decision(request, run_index, error)
              {
                'run_index' => run_index,
                'source_index' => request['_benchmark_source_index'],
                'cell_ids' => request_cell_ids(request),
                'face_counts' => request['_benchmark_face_counts'],
                'max_face_count' => request['_benchmark_max_face_count'],
                'face_bucket' => request['_benchmark_face_bucket'],
                'path' => nil,
                'final_status' => 'error',
                'tolerated' => false,
                'actual_overlap_volume_mm3' => nil,
                'component_count' => nil,
                'elapsed_ms' => nil,
                'error' => true,
                'error_class' => error.class.name,
                'error_message' => error.message,
                'backtrace' => Array(error.backtrace)
              }
            end

            def compare(off_rows, on_rows)
              off_by_index = index_by_source(off_rows)
              on_by_index = index_by_source(on_rows)
              all_indexes = (off_by_index.keys | on_by_index.keys).sort
              status_mismatches = []
              tolerated_mismatches = []
              kept_volume_mismatches = []
              kept_component_mismatches = []
              missing_rows = []

              transitions = Hash.new(0)
              all_indexes.each do |source_index|
                off = off_by_index[source_index]
                on = on_by_index[source_index]
                unless off && on
                  missing_rows << {
                    'source_index' => source_index,
                    'adaptive_off_missing' => off.nil?,
                    'adaptive_on_missing' => on.nil?
                  }
                  next
                end

                transition = "#{off['final_status']}=>#{on['final_status']}"
                transitions[transition] += 1
                if off['final_status'] != on['final_status']
                  status_mismatches << mismatch_row(off, on)
                end
                if off['tolerated'] != on['tolerated']
                  tolerated_mismatches << mismatch_row(off, on)
                end
                next unless kept_status?(off['final_status']) &&
                  kept_status?(on['final_status'])

                unless volume_equivalent?(
                  off['actual_overlap_volume_mm3'],
                  on['actual_overlap_volume_mm3']
                )
                  kept_volume_mismatches << mismatch_row(off, on)
                end
                if off['component_count'] != on['component_count']
                  kept_component_mismatches << mismatch_row(off, on)
                end
              end

              {
                'transitions' => transitions.sort.to_h,
                'status_mismatch_count' => status_mismatches.length,
                'status_mismatches' => status_mismatches,
                'tolerated_mismatch_count' => tolerated_mismatches.length,
                'tolerated_mismatches' => tolerated_mismatches,
                'kept_volume_mismatch_count' => kept_volume_mismatches.length,
                'kept_volume_mismatches' => kept_volume_mismatches,
                'kept_component_mismatch_count' =>
                  kept_component_mismatches.length,
                'kept_component_mismatches' => kept_component_mismatches,
                'missing_row_count' => missing_rows.length,
                'missing_rows' => missing_rows
              }
            end

            def performance_breakdown(
              off_rows,
              on_rows,
              off_elapsed_ms,
              on_elapsed_ms
            )
              {
                'total' => performance_row(
                  'all',
                  off_rows,
                  on_rows,
                  off_elapsed_ms,
                  on_elapsed_ms
                ),
                'by_final_status' => grouped_performance(
                  off_rows,
                  on_rows
                ) { |row| row['final_status'].to_s },
                'by_max_face_count' => grouped_performance(
                  off_rows,
                  on_rows
                ) { |row| row['face_bucket'].to_s }
              }
            end

            def grouped_performance(off_rows, on_rows)
              off_groups = off_rows.group_by { |row| yield(row) }
              on_groups = on_rows.group_by { |row| yield(row) }
              keys = (off_groups.keys | on_groups.keys).sort
              keys.each_with_object({}) do |key, output|
                output[key] = performance_row(
                  key,
                  off_groups.fetch(key, []),
                  on_groups.fetch(key, []),
                  sum_elapsed(off_groups.fetch(key, [])),
                  sum_elapsed(on_groups.fetch(key, []))
                )
              end
            end

            def performance_row(
              label,
              off_rows,
              on_rows,
              off_elapsed_ms,
              on_elapsed_ms
            )
              baseline = off_elapsed_ms.to_f
              adaptive = on_elapsed_ms.to_f
              reduction = baseline - adaptive
              {
                'label' => label,
                'request_count' => [off_rows.length, on_rows.length].max,
                'adaptive_off_elapsed_ms' => baseline,
                'adaptive_on_elapsed_ms' => adaptive,
                'delta_ms' => adaptive - baseline,
                'speedup_x' => adaptive.positive? ? baseline / adaptive : nil,
                'reduction_percent' => baseline.positive? ?
                  (reduction / baseline) * 100.0 : nil,
                'adaptive_off_pair_median_ms' => median(pair_times(off_rows)),
                'adaptive_on_pair_median_ms' => median(pair_times(on_rows))
              }
            end

            def aggregate_iterations(iteration_rows)
              total_rows = iteration_rows.map do |iteration|
                iteration.fetch('performance').fetch('total')
              end
              {
                'iteration_count' => iteration_rows.length,
                'all_iterations_passed' =>
                  iteration_rows.all? { |row| row['pass'] == true },
                'adaptive_off_elapsed_ms_median' => median(
                  total_rows.map { |row| row['adaptive_off_elapsed_ms'] }
                ),
                'adaptive_on_elapsed_ms_median' => median(
                  total_rows.map { |row| row['adaptive_on_elapsed_ms'] }
                ),
                'speedup_x_median' => median(
                  total_rows.map { |row| row['speedup_x'] }.compact
                ),
                'reduction_percent_median' => median(
                  total_rows.map { |row| row['reduction_percent'] }.compact
                ),
                'by_final_status' => aggregate_grouped(
                  iteration_rows,
                  'by_final_status'
                ),
                'by_max_face_count' => aggregate_grouped(
                  iteration_rows,
                  'by_max_face_count'
                )
              }
            end

            def aggregate_grouped(iteration_rows, group_key)
              keys = iteration_rows.flat_map do |iteration|
                iteration.fetch('performance').fetch(group_key).keys
              end.uniq.sort
              keys.each_with_object({}) do |key, output|
                rows = iteration_rows.filter_map do |iteration|
                  iteration.fetch('performance').fetch(group_key)[key]
                end
                output[key] = {
                  'request_count' => rows.map { |row| row['request_count'] }.max,
                  'adaptive_off_elapsed_ms_median' => median(
                    rows.map { |row| row['adaptive_off_elapsed_ms'] }
                  ),
                  'adaptive_on_elapsed_ms_median' => median(
                    rows.map { |row| row['adaptive_on_elapsed_ms'] }
                  ),
                  'speedup_x_median' => median(
                    rows.map { |row| row['speedup_x'] }.compact
                  ),
                  'reduction_percent_median' => median(
                    rows.map { |row| row['reduction_percent'] }.compact
                  )
                }
              end
            end

            def iteration_pass?(iteration, expected_count)
              off = iteration.fetch('adaptive_off')
              on = iteration.fetch('adaptive_on')
              comparison = iteration.fetch('comparison')
              off['decision_count'] == expected_count &&
                on['decision_count'] == expected_count &&
                off['error_count'].zero? &&
                on['error_count'].zero? &&
                off['path_violation_count'].zero? &&
                on['path_violation_count'].zero? &&
                comparison['status_mismatch_count'].zero? &&
                comparison['tolerated_mismatch_count'].zero? &&
                comparison['kept_volume_mismatch_count'].zero? &&
                comparison['kept_component_mismatch_count'].zero? &&
                comparison['missing_row_count'].zero?
            end

            def path_violation?(kind, path)
              kind == :adaptive_off ? path.to_s == DIRECT_FULL_PATH.to_s :
                path.to_s != DIRECT_FULL_PATH.to_s
            end

            def kept_status?(status)
              status.to_s == 'kept'
            end

            def volume_equivalent?(left, right)
              return left.nil? && right.nil? if left.nil? || right.nil?

              scale = [left.abs, right.abs, 1.0].max
              (left - right).abs <= (scale * 1.0e-6)
            end

            def mismatch_row(off, on)
              {
                'source_index' => off['source_index'],
                'cell_ids' => off['cell_ids'],
                'face_counts' => off['face_counts'],
                'max_face_count' => off['max_face_count'],
                'face_bucket' => off['face_bucket'],
                'adaptive_off' => compact_decision(off),
                'adaptive_on' => compact_decision(on)
              }
            end

            def compact_decision(row)
              {
                'path' => row['path'],
                'final_status' => row['final_status'],
                'tolerated' => row['tolerated'],
                'actual_overlap_volume_mm3' =>
                  row['actual_overlap_volume_mm3'],
                'component_count' => row['component_count'],
                'elapsed_ms' => row['elapsed_ms'],
                'error' => row['error']
              }
            end

            def print_run_summary(prefix, run)
              puts format(
                '%s elapsed=%.3f ms requests=%d errors=%d path_violations=%d',
                prefix,
                run['elapsed_ms'],
                run['request_count'],
                run['error_count'],
                run['path_violation_count']
              )
              puts "#{prefix} paths=#{run['path_counts'].inspect}"
              puts "#{prefix} statuses=#{run['status_counts'].inspect}"
            end

            def print_comparison(comparison)
              puts "transitions=#{comparison['transitions'].inspect}"
              puts format(
                'mismatches status=%d tolerated=%d kept_volume=%d ' \
                'kept_components=%d missing=%d',
                comparison['status_mismatch_count'],
                comparison['tolerated_mismatch_count'],
                comparison['kept_volume_mismatch_count'],
                comparison['kept_component_mismatch_count'],
                comparison['missing_row_count']
              )
            end

            def print_performance(performance)
              puts "performance=#{format_performance(performance['total'])}"
              puts 'BY FINAL STATUS'
              performance.fetch('by_final_status').each do |key, row|
                puts "  #{key}: #{format_performance(row)}"
              end
              puts 'BY MAX FACE COUNT'
              performance.fetch('by_max_face_count').each do |key, row|
                puts "  #{key}: #{format_performance(row)}"
              end
            end

            def print_aggregate(aggregate)
              return unless aggregate

              puts '=== AGGREGATE MEDIANS ==='
              puts format(
                'OFF=%.3f ms ON=%.3f ms speedup=%s reduction=%s%%',
                aggregate['adaptive_off_elapsed_ms_median'],
                aggregate['adaptive_on_elapsed_ms_median'],
                format_optional(aggregate['speedup_x_median']),
                format_optional(aggregate['reduction_percent_median'])
              )
              puts 'BY FINAL STATUS'
              aggregate.fetch('by_final_status').each do |key, row|
                puts "  #{key}: #{format_aggregate_group(row)}"
              end
              puts 'BY MAX FACE COUNT'
              aggregate.fetch('by_max_face_count').each do |key, row|
                puts "  #{key}: #{format_aggregate_group(row)}"
              end
            end

            def format_performance(row)
              format(
                'n=%d OFF=%.3f ms ON=%.3f ms speedup=%s reduction=%s%% ' \
                'pair_median=%s=>%s ms',
                row['request_count'],
                row['adaptive_off_elapsed_ms'],
                row['adaptive_on_elapsed_ms'],
                format_optional(row['speedup_x']),
                format_optional(row['reduction_percent']),
                format_optional(row['adaptive_off_pair_median_ms']),
                format_optional(row['adaptive_on_pair_median_ms'])
              )
            end

            def format_aggregate_group(row)
              format(
                'n=%d OFF=%.3f ms ON=%.3f ms speedup=%s reduction=%s%%',
                row['request_count'],
                row['adaptive_off_elapsed_ms_median'],
                row['adaptive_on_elapsed_ms_median'],
                format_optional(row['speedup_x_median']),
                format_optional(row['reduction_percent_median'])
              )
            end

            def format_optional(value)
              value.nil? ? 'nil' : format('%.3f', value)
            end

            def request_cell_ids(request)
              ids = request['cell_ids'] || request[:cell_ids]
              return Array(ids).map(&:to_s) if ids

              [
                request['cell_id1'] || request[:cell_id1],
                request['cell_id2'] || request[:cell_id2]
              ].compact.map(&:to_s)
            end

            def resolve_cell_group(cell_id, indoor_model, cache)
              key = cell_id.to_s
              return cache[key] if cache.key?(key)

              feature = resolve_cell_feature(key, indoor_model)
              cache[key] = feature_group(feature)
            end

            def resolve_cell_feature(cell_id, indoor_model)
              registry = feature_registry(indoor_model)
              feature = if registry.respond_to?(:find_cell_space_by_id)
                registry.find_cell_space_by_id(cell_id)
              elsif registry.respond_to?(:cell_space_by_id)
                registry.cell_space_by_id(cell_id)
              elsif registry.respond_to?(:find_by_id)
                registry.find_by_id(cell_id)
              end
              feature ||= indoor_model.find_cell_space_by_id(cell_id) if
                indoor_model.respond_to?(:find_cell_space_by_id)
              feature
            end

            def feature_registry(indoor_model)
              return indoor_model.feature_registry if
                indoor_model.respond_to?(:feature_registry)
              return indoor_model.registry if indoor_model.respond_to?(:registry)

              indoor_model
            end

            def feature_group(feature)
              return nil unless feature
              return feature.group if feature.respond_to?(:group)
              return feature.entity if feature.respond_to?(:entity)
              return feature.sketchup_entity if
                feature.respond_to?(:sketchup_entity)

              feature
            end

            def entity_alive?(entity)
              return false if entity.respond_to?(:deleted?) && entity.deleted?
              return entity.valid? if entity.respond_to?(:valid?)

              true
            rescue StandardError
              false
            end

            def face_count(group)
              entities = group.respond_to?(:entities) ? group.entities : nil
              return 0 unless entities

              if defined?(Sketchup::Face)
                entities.grep(Sketchup::Face).length
              else
                entities.count do |entity|
                  entity.class.name.to_s.end_with?('Face')
                end
              end
            end

            def face_bucket(max_face_count)
              bucket = FACE_BUCKETS.find do |_label, minimum, maximum|
                max_face_count >= minimum && max_face_count <= maximum
              end
              bucket ? bucket.first : 'outside_threshold'
            end

            def decision_value(decision, key)
              return nil unless decision.respond_to?(:[])

              decision[key] || decision[key.to_sym]
            end

            def deep_dup(value)
              Marshal.load(Marshal.dump(value))
            rescue StandardError
              normalize_hash(value)
            end

            def normalize_hash(value)
              case value
              when Hash
                value.each_with_object({}) do |(key, item), output|
                  output[key.to_s] = normalize_hash(item)
                end
              when Array
                value.map { |item| normalize_hash(item) }
              else
                value
              end
            end

            def truthy_or_false(value)
              value == true
            end

            def numeric_or_nil(value)
              Float(value)
            rescue StandardError
              nil
            end

            def integer_or_nil(value)
              Integer(value)
            rescue StandardError
              nil
            end

            def elapsed_since(started)
              (
                Process.clock_gettime(CLOCK) - started
              ) * 1000.0
            end

            def sum_elapsed(rows)
              pair_times(rows).sum
            end

            def pair_times(rows)
              rows.filter_map { |row| numeric_or_nil(row['elapsed_ms']) }
            end

            def median(values)
              sorted = Array(values).compact.map(&:to_f).sort
              return nil if sorted.empty?

              middle = sorted.length / 2
              return sorted[middle] if sorted.length.odd?

              (sorted[middle - 1] + sorted[middle]) / 2.0
            end

            def index_by_source(rows)
              rows.each_with_object({}) do |row, output|
                output[row['source_index']] = row
              end
            end

            def tally(rows)
              rows.each_with_object(Hash.new(0)) do |row, counts|
                counts[yield(row)] += 1
              end.sort.to_h
            end

            def benchmark_output_directory(directory, report_name)
              root = File.join(directory, 'adaptive_ab_benchmark')
              label = report_name.to_s.strip
              label = Time.now.strftime('%Y%m%d-%H%M%S') if label.empty?
              File.join(root, sanitize_filename(label))
            end

            def sanitize_filename(value)
              value.to_s.gsub(/[^0-9A-Za-z._-]+/, '_')
            end

            def write_progress(io, payload)
              io.write(JSON.generate(payload.merge('at' => Time.now.iso8601(6))))
              io.write("\n")
              io.flush
            end
          end
        end
      end
    end
  end
end
