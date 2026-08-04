# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

require_relative 'val3dity_recheck_snapshot_store'
require_relative 'val3dity_recheck_v3_mesh_proxy_fallback_fix'
require_relative 'val3dity_recheck_v3_mesh_proxy_benchmark'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only repeated-session benchmark with strict preflight validation.
        # It refuses to treat a stable all-inconclusive result as a successful
        # stability run. Production recheck code is not modified.
        module Val3dityRecheckV3MeshProxyRepeatBenchmarkV2
          MODE = 'recheck_only_v3_mesh_proxy_repeated_session_v2'

          class << self
            attr_reader :last_result_path, :last_progress_log_path, :last_result

            def run_snapshot(name_or_path = nil, rounds: 10, limit: 20,
                             time_budget_seconds: 120,
                             report_name: nil, output_dir: nil,
                             indoor_model: nil)
              rounds = rounds.to_i
              raise ArgumentError, 'rounds must be positive.' unless rounds.positive?

              store = Val3dityRecheckSnapshotStore
              snapshot_dir = store.resolve_directory(name_or_path)
              request_path = store.request_path(name_or_path)
              raise 'Persistent recheck snapshot was not found.' unless
                snapshot_dir && request_path && File.file?(request_path)

              all_requests = Val3dityRecheckOnlyRunner.requests_from_file(request_path)
              requests = all_requests.first([limit.to_i, 0].max)
              raise 'Selected recheck request list is empty.' if requests.empty?

              indoor_model ||= IndoorCore::IndoorModel.current
              model = Sketchup.active_model
              raise 'IndoorModel.current is not bound to the active model.' unless
                indoor_model&.model == model

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              name = sanitize(report_name || "v3_mesh_proxy_repeat_v2_#{stamp}")
              directory = File.expand_path(
                output_dir || File.join(
                  snapshot_dir, 'benchmarks', 'v3_mesh_proxy_repeat_v2', stamp
                )
              )
              FileUtils.mkdir_p(directory)
              progress_path = File.join(directory, 'progress.jsonl')
              result_path = File.join(directory, "#{name}.json")
              @last_progress_log_path = progress_path
              @last_result_path = result_path

              started = clock
              preflight = preflight_snapshot(indoor_model, requests)
              rows = []
              reference_signature = nil
              fatal_reason = nil

              File.open(progress_path, 'a:UTF-8') do |io|
                io.sync = true
                append_progress(io, {
                  'event' => 'start',
                  'generated_at' => Time.now.iso8601(6),
                  'mode' => MODE,
                  'round_count' => rounds,
                  'limit' => requests.length,
                  'time_budget_seconds' => time_budget_seconds,
                  'preflight' => preflight
                })

                unless preflight['all_request_cells_resolved'] == true
                  fatal_reason = 'preflight_cellspace_resolution_failed'
                  append_progress(io, {
                    'event' => 'preflight_failed',
                    'generated_at' => Time.now.iso8601(6),
                    'reason' => fatal_reason,
                    'preflight' => preflight
                  })
                end

                rounds.times do |index|
                  break if fatal_reason

                  round_number = index + 1
                  before = diagnostic_snapshot(model, indoor_model)
                  round_started = clock
                  append_progress(io, {
                    'event' => 'round_start',
                    'generated_at' => Time.now.iso8601(6),
                    'round' => round_number,
                    'elapsed_seconds' => (clock - started).round(6),
                    'diagnostic' => before
                  })

                  result = Val3dityRecheckV3MeshProxyBenchmark.run_snapshot(
                    name_or_path,
                    report_name: format('%s_round_%02d', name, round_number),
                    limit: requests.length,
                    time_budget_seconds: time_budget_seconds,
                    indoor_model: indoor_model
                  )
                  live = result.fetch('v3_mesh_proxy')
                  decisions = Array(live['decisions'])
                  signature = decision_signature(decisions)
                  reference_signature ||= signature
                  after = diagnostic_snapshot(model, indoor_model)
                  reasons = decisions.map { |row| row['reason'].to_s }.tally.sort.to_h
                  proxy_missing_count = decisions.count { |row| row['proxy'].nil? }
                  all_inconclusive = live.dig('status_counts', 'inconclusive').to_i ==
                                     decisions.length && !decisions.empty?
                  direct_path_exercised = live.dig('path_counts', 'v3_direct_mesh_proxy').to_i.positive?
                  fallback_path_exercised = live.dig(
                    'path_counts', 'original_full_recheck_fallback'
                  ).to_i.positive?

                  row = {
                    'round' => round_number,
                    'elapsed_ms' => elapsed_ms(round_started),
                    'benchmark_elapsed_ms' => live['elapsed_ms'],
                    'processed_request_count' => live['processed_request_count'],
                    'aborted' => live['aborted'] == true,
                    'abort_reason' => live['abort_reason'],
                    'status_counts' => live['status_counts'],
                    'path_counts' => live['path_counts'],
                    'fallback_reason_counts' => live['fallback_reason_counts'],
                    'reason_counts' => reasons,
                    'proxy_missing_count' => proxy_missing_count,
                    'all_inconclusive' => all_inconclusive,
                    'direct_path_exercised' => direct_path_exercised,
                    'fallback_path_exercised' => fallback_path_exercised,
                    'error_count' => Array(live['errors']).length,
                    'decision_signature_match' => signature == reference_signature,
                    'max_pair_elapsed_ms' => decisions.map do |decision|
                      decision['pair_elapsed_ms'].to_f
                    end.max,
                    'last_pair_elapsed_ms' => decisions.last&.fetch('pair_elapsed_ms', nil),
                    'sample_decisions' => decisions.first(3).map do |decision|
                      {
                        'cells' => decision['cells'],
                        'status' => decision['status'],
                        'reason' => decision['reason'],
                        'proxy_path' => decision.dig('proxy', 'path'),
                        'fallback_reason' => decision.dig('proxy', 'fallback_reason')
                      }
                    end,
                    'before' => before,
                    'after' => after,
                    'diagnostic_delta' => diagnostic_delta(before, after),
                    'benchmark_result_path' =>
                      Val3dityRecheckV3MeshProxyBenchmark.last_result_path,
                    'benchmark_progress_log_path' =>
                      Val3dityRecheckV3MeshProxyBenchmark.last_progress_log_path
                  }
                  rows << row
                  append_progress(io, row.merge(
                    'event' => 'round_complete',
                    'generated_at' => Time.now.iso8601(6),
                    'elapsed_seconds' => (clock - started).round(6)
                  ))

                  if round_number == 1 && (all_inconclusive || !direct_path_exercised)
                    fatal_reason = all_inconclusive ?
                      'first_round_all_inconclusive' : 'first_round_direct_path_not_exercised'
                    append_progress(io, {
                      'event' => 'validation_failed',
                      'generated_at' => Time.now.iso8601(6),
                      'round' => round_number,
                      'reason' => fatal_reason,
                      'status_counts' => live['status_counts'],
                      'path_counts' => live['path_counts'],
                      'reason_counts' => reasons,
                      'sample_decisions' => row['sample_decisions']
                    })
                  end
                rescue StandardError => e
                  fatal_reason = "#{e.class}: #{e.message}"
                  rows << {
                    'round' => round_number,
                    'error' => fatal_reason,
                    'backtrace' => Array(e.backtrace).first(20)
                  }
                  append_progress(io, {
                    'event' => 'round_error',
                    'generated_at' => Time.now.iso8601(6),
                    'round' => round_number,
                    'error' => fatal_reason,
                    'backtrace' => Array(e.backtrace).first(20)
                  })
                end

                payload = {
                  'schema_version' => 2,
                  'generated_at' => Time.now.iso8601(6),
                  'mode' => MODE,
                  'production_code_modified' => false,
                  'snapshot_directory' => snapshot_dir,
                  'round_count_requested' => rounds,
                  'round_count_completed' => rows.count { |row| !row.key?('error') },
                  'limit' => requests.length,
                  'time_budget_seconds' => time_budget_seconds,
                  'elapsed_ms' => elapsed_ms(started),
                  'preflight' => preflight,
                  'fatal_reason' => fatal_reason,
                  'valid_stability_run' => fatal_reason.nil?,
                  'decision_signatures_stable' =>
                    fatal_reason.nil? && rows.all? do |row|
                      row['decision_signature_match'] != false
                    end,
                  'rounds' => rows,
                  'progress_log_path' => progress_path
                }
                File.write(result_path, JSON.pretty_generate(payload), encoding: 'UTF-8')
                append_progress(io, {
                  'event' => 'finish',
                  'generated_at' => Time.now.iso8601(6),
                  'elapsed_seconds' => (clock - started).round(6),
                  'result_path' => result_path,
                  'round_count_completed' => payload['round_count_completed'],
                  'valid_stability_run' => payload['valid_stability_run'],
                  'fatal_reason' => fatal_reason
                })
                @last_result = payload
              end

              @last_result
            end

            private

            def preflight_snapshot(indoor_model, requests)
              cell_spaces = Array(indoor_model&.cell_spaces)
              index = {}
              used = {}
              cell_spaces.each do |cell_space|
                runtime_id = cell_space&.id.to_s
                index[runtime_id] = cell_space unless runtime_id.empty?
              end
              cell_spaces.each do |cell_space|
                normalized = safe_report_id(cell_space&.id)
                normalized = 'missing' if normalized.empty?
                base = "cell_#{normalized}"
                report_id = base
                suffix = 2
                while used[report_id]
                  report_id = "#{base}_#{suffix}"
                  suffix += 1
                end
                used[report_id] = true
                index[report_id] = cell_space
              end

              requested_ids = requests.flat_map { |row| Array(row['cells']) }.map(&:to_s).uniq
              unresolved = requested_ids.reject { |cell_id| index[cell_id] }
              invalid = requested_ids.filter_map do |cell_id|
                cell_space = index[cell_id]
                next unless cell_space

                group = cell_space.sketchup_group
                cell_id unless group&.valid?
              rescue StandardError
                cell_id
              end
              {
                'runtime_cell_space_count' => cell_spaces.length,
                'valid_runtime_cell_space_count' => cell_spaces.count do |cell_space|
                  cell_space&.sketchup_group&.valid?
                rescue StandardError
                  false
                end,
                'request_cell_id_count' => requested_ids.length,
                'resolved_request_cell_id_count' => requested_ids.length - unresolved.length,
                'unresolved_request_cell_ids' => unresolved,
                'invalid_request_cell_ids' => invalid,
                'all_request_cells_resolved' => unresolved.empty? && invalid.empty?
              }
            end

            def safe_report_id(value)
              value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
            end

            def decision_signature(decisions)
              Array(decisions).map do |decision|
                proxy = decision['proxy'] || {}
                [
                  decision['code'].to_i,
                  Array(decision['cells']).map(&:to_s).sort,
                  decision['status'].to_s,
                  decision['tolerated'] == true,
                  decision['reason'].to_s,
                  proxy['path'].to_s,
                  proxy['fallback_reason'].to_s,
                  proxy['intersection_status'].to_s,
                  proxy['intersection_reason'].to_s
                ]
              end
            end

            def diagnostic_snapshot(model, indoor_model)
              gc = GC.stat
              {
                'root_entity_count' => safe_count(model&.entities),
                'active_entity_count' => safe_count(model&.active_entities),
                'definition_count' => safe_count(model&.definitions),
                'runtime_cell_space_count' => safe_count(indoor_model&.cell_spaces),
                'operation_depth' => indoor_model.instance_variable_get(
                  :@indoor_operation_depth
                ).to_i,
                'gc_heap_live_slots' => gc[:heap_live_slots].to_i,
                'gc_heap_allocated_pages' => gc[:heap_allocated_pages].to_i,
                'gc_total_allocated_objects' => gc[:total_allocated_objects].to_i,
                'gc_total_freed_objects' => gc[:total_freed_objects].to_i
              }
            rescue StandardError => e
              { 'diagnostic_error' => "#{e.class}: #{e.message}" }
            end

            def diagnostic_delta(before, after)
              keys = %w[
                root_entity_count active_entity_count definition_count
                runtime_cell_space_count operation_depth gc_heap_live_slots
                gc_heap_allocated_pages gc_total_allocated_objects
                gc_total_freed_objects
              ]
              keys.each_with_object({}) do |key, delta|
                next unless before[key].is_a?(Numeric) && after[key].is_a?(Numeric)

                delta[key] = after[key] - before[key]
              end
            end

            def safe_count(collection)
              return nil unless collection

              collection.respond_to?(:length) ? collection.length : collection.to_a.length
            rescue StandardError
              nil
            end

            def append_progress(io, payload)
              io.write(JSON.generate(payload))
              io.write("\n")
              io.flush
            end

            def sanitize(value)
              text = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              text.empty? ? 'v3_mesh_proxy_repeat_v2' : text
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
