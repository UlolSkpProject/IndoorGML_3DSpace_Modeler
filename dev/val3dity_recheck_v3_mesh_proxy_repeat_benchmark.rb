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
        # Dev-only repeated-session benchmark for the v3 direct mesh proxy.
        # It reruns the same selected request prefix in one SketchUp session and
        # records decision stability, model residue, operation depth, and GC
        # growth. Production recheck code is not modified.
        module Val3dityRecheckV3MeshProxyRepeatBenchmark
          MODE = 'recheck_only_v3_mesh_proxy_repeated_session'

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
              raise 'Persistent recheck snapshot was not found.' unless snapshot_dir

              indoor_model ||= IndoorCore::IndoorModel.current
              model = Sketchup.active_model
              raise 'IndoorModel.current is not bound to the active model.' unless
                indoor_model&.model == model

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              name = sanitize(report_name || "v3_mesh_proxy_repeat_#{stamp}")
              directory = File.expand_path(
                output_dir || File.join(
                  snapshot_dir, 'benchmarks', 'v3_mesh_proxy_repeat', stamp
                )
              )
              FileUtils.mkdir_p(directory)
              progress_path = File.join(directory, 'progress.jsonl')
              result_path = File.join(directory, "#{name}.json")
              @last_progress_log_path = progress_path
              @last_result_path = result_path

              started = clock
              rows = []
              reference_signature = nil
              initial_diagnostic = diagnostic_snapshot(model, indoor_model)

              File.open(progress_path, 'a:UTF-8') do |io|
                io.sync = true
                append_progress(io, {
                  'event' => 'start',
                  'generated_at' => Time.now.iso8601(6),
                  'mode' => MODE,
                  'round_count' => rounds,
                  'limit' => limit,
                  'time_budget_seconds' => time_budget_seconds,
                  'diagnostic' => initial_diagnostic
                })

                rounds.times do |index|
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
                    limit: limit,
                    time_budget_seconds: time_budget_seconds
                  )
                  live = result.fetch('v3_mesh_proxy')
                  signature = decision_signature(live.fetch('decisions'))
                  reference_signature ||= signature
                  signature_match = signature == reference_signature
                  after = diagnostic_snapshot(model, indoor_model)

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
                    'error_count' => Array(live['errors']).length,
                    'decision_signature_match' => signature_match,
                    'max_pair_elapsed_ms' => Array(live['decisions']).map do |decision|
                      decision['pair_elapsed_ms'].to_f
                    end.max,
                    'last_pair_elapsed_ms' => Array(live['decisions']).last&.fetch(
                      'pair_elapsed_ms', nil
                    ),
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
                rescue StandardError => e
                  row = {
                    'round' => round_number,
                    'elapsed_ms' => elapsed_ms(round_started),
                    'error' => "#{e.class}: #{e.message}",
                    'backtrace' => Array(e.backtrace).first(20),
                    'before' => before,
                    'after' => diagnostic_snapshot(model, indoor_model)
                  }
                  rows << row
                  append_progress(io, row.merge(
                    'event' => 'round_error',
                    'generated_at' => Time.now.iso8601(6),
                    'elapsed_seconds' => (clock - started).round(6)
                  ))
                  break
                end

                final_diagnostic = diagnostic_snapshot(model, indoor_model)
                payload = {
                  'schema_version' => 1,
                  'generated_at' => Time.now.iso8601(6),
                  'mode' => MODE,
                  'production_code_modified' => false,
                  'snapshot_directory' => snapshot_dir,
                  'round_count_requested' => rounds,
                  'round_count_completed' => rows.count { |row| !row.key?('error') },
                  'limit' => limit,
                  'time_budget_seconds' => time_budget_seconds,
                  'elapsed_ms' => elapsed_ms(started),
                  'initial_diagnostic' => initial_diagnostic,
                  'final_diagnostic' => final_diagnostic,
                  'session_diagnostic_delta' => diagnostic_delta(
                    initial_diagnostic, final_diagnostic
                  ),
                  'decision_signatures_stable' => rows.all? do |row|
                    row['decision_signature_match'] != false
                  end,
                  'rounds' => rows,
                  'progress_log_path' => progress_path
                }
                File.write(
                  result_path,
                  JSON.pretty_generate(payload),
                  encoding: 'UTF-8'
                )
                append_progress(io, {
                  'event' => 'finish',
                  'generated_at' => Time.now.iso8601(6),
                  'elapsed_seconds' => (clock - started).round(6),
                  'result_path' => result_path,
                  'round_count_completed' => payload['round_count_completed'],
                  'decision_signatures_stable' =>
                    payload['decision_signatures_stable'],
                  'session_diagnostic_delta' =>
                    payload['session_diagnostic_delta']
                })
                @last_result = payload
              end

              @last_result
            end

            private

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
                operation_depth gc_heap_live_slots gc_heap_allocated_pages
                gc_total_allocated_objects gc_total_freed_objects
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
              text.empty? ? 'v3_mesh_proxy_repeat' : text
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
