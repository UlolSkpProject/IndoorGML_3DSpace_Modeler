# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'

require_relative 'val3dity_recheck_snapshot_store'
require_relative 'val3dity_recheck_v3_mesh_proxy_non_solid_fallback'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3CurrentPairedBenchmark
          class << self
            attr_reader :last_result_path, :last_progress_log_path, :last_snapshot

            def run_snapshot(name_or_path = nil, report_name: nil, indoor_model: nil)
              store = Val3dityRecheckSnapshotStore
              dir = store.resolve_directory(name_or_path)
              req_path = store.request_path(name_or_path)
              raise 'Persistent recheck snapshot was not found.' unless dir && File.file?(req_path)

              requests = Val3dityRecheckOnlyRunner.requests_from_file(req_path)
              indoor_model ||= IndoorCore::IndoorModel.current
              unless indoor_model&.model == Sketchup.active_model
                raise 'IndoorModel.current is not bound to the active SketchUp model.'
              end

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              out = File.join(dir, 'final_current_paired', stamp)
              FileUtils.mkdir_p(out)
              name = sanitize(report_name || "current_full_vs_v3_#{stamp}")
              @last_result_path = File.join(out, "#{name}.json")
              @last_progress_log_path = File.join(out, 'progress.jsonl')

              full = nil
              v3 = nil
              File.open(@last_progress_log_path, 'w:UTF-8') do |io|
                io.sync = true
                write(io, event: 'start', request_count: requests.length)
                full = execute(requests, indoor_model, :full, io)
                v3 = execute(requests, indoor_model, :v3, io)
              end

              comparison = compare(full['decisions'], v3['decisions'])
              completed = [full, v3].all? do |run|
                run['processed_request_count'] == requests.length && run['errors'].empty?
              end
              pass = completed && comparison.values_at(
                'suppressed_regression_count',
                'kept_regression_count',
                'kept_volume_mismatch_count'
              ).all?(&:zero?)

              full_ms = full['elapsed_ms'].to_f
              v3_ms = v3['elapsed_ms'].to_f
              snapshot = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'mode' => 'current_full_vs_v3_live_paired_benchmark',
                'production_decision_modified' => false,
                'validation_report_modified' => false,
                'source_snapshot_directory' => dir,
                'request_path' => req_path,
                'request_sha256' => Digest::SHA256.file(req_path).hexdigest,
                'request_count' => requests.length,
                'full' => full,
                'v3' => v3,
                'comparison' => comparison,
                'timing' => {
                  'full_elapsed_ms' => full_ms.round(3),
                  'v3_elapsed_ms' => v3_ms.round(3),
                  'speedup_vs_full' => v3_ms.positive? ? (full_ms / v3_ms).round(3) : nil
                },
                'completed' => completed,
                'final_pass' => pass
              }
              File.write(@last_result_path, JSON.pretty_generate(snapshot), encoding: 'UTF-8')
              File.open(@last_progress_log_path, 'a:UTF-8') do |io|
                write(io, event: 'finish', final_pass: pass, comparison: comparison)
              end
              @last_snapshot = snapshot
            end

            def print_report(result = @last_snapshot)
              raise 'No benchmark result is available.' unless result

              c = result['comparison']
              puts
              puts('=' * 110)
              puts('CURRENT FULL vs V3 FINAL PAIRED BENCHMARK')
              puts('=' * 110)
              puts "request_count                    : #{result['request_count']}"
              puts "full_status_counts               : #{result.dig('full', 'status_counts')}"
              puts "v3_status_counts                 : #{result.dig('v3', 'status_counts')}"
              puts "transition_counts                : #{c['transition_counts']}"
              puts "suppressed_regression_count      : #{c['suppressed_regression_count']}"
              puts "kept_regression_count            : #{c['kept_regression_count']}"
              puts "kept_volume_mismatch_count       : #{c['kept_volume_mismatch_count']}"
              puts "inconclusive_to_suppressed_count : #{c['inconclusive_to_suppressed_count']}"
              puts "v3_path_counts                   : #{result.dig('v3', 'path_counts')}"
              puts "v3_fallback_reason_counts        : #{result.dig('v3', 'fallback_reason_counts')}"
              puts "full_elapsed_ms                  : #{result.dig('timing', 'full_elapsed_ms')}"
              puts "v3_elapsed_ms                    : #{result.dig('timing', 'v3_elapsed_ms')}"
              puts "speedup_vs_full                  : #{result.dig('timing', 'speedup_vs_full')}"
              puts "completed                        : #{result['completed']}"
              puts "FINAL PASS                       : #{result['final_pass']}"
              puts "result_path                      : #{@last_result_path}"
              puts "progress_path                    : #{@last_progress_log_path}"
              puts('=' * 110)
              result
            end

            private

            def execute(requests, model, kind, io)
              runner = Val3dityRunner.new(
                File.join(File.dirname(@last_result_path), "__#{kind}.gml"),
                report_name: kind.to_s,
                work_dir: File.dirname(@last_result_path),
                indoor_model: model
              )
              klass = kind == :v3 ?
                Val3dityRecheckV3MeshProxy::Rechecker :
                Val3dityOverlapGeometryRechecker
              checker = klass.new(
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
              requests.each_with_index do |request, index|
                pair_started = clock
                result = runner.send(
                  :recheck_cell_pair,
                  request['code'],
                  request['cells'][0],
                  request['cells'][1]
                )
                row = {
                  'index' => index,
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'status' => value(result, 'status').to_s,
                  'tolerated' => value(result, 'tolerated'),
                  'reason' => value(result, 'reason').to_s,
                  'volume' => value(result, 'actual_overlap_volume'),
                  'component_count' => value(result, 'intersection_component_count'),
                  'elapsed_ms' => elapsed(pair_started)
                }
                row['proxy'] = checker.proxy_record(*request['cells']) if kind == :v3
                rows << row
                counts[row['status']] += 1
                write(io, event: 'pair', pipeline: kind, index: index, status: row['status'])
              rescue StandardError => e
                counts['error'] += 1
                errors << {
                  'index' => index,
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'error' => "#{e.class}: #{e.message}"
                }
              end

              records = kind == :v3 ? checker.proxy_records.values : []
              fallback = records.select { |row| row['path'] == 'original_full_recheck_fallback' }
              {
                'elapsed_ms' => elapsed(started),
                'processed_request_count' => rows.length + errors.length,
                'status_counts' => counts.sort.to_h,
                'path_counts' => records.map { |r| r['path'] || 'missing' }.tally.sort.to_h,
                'fallback_reason_counts' => fallback.map { |r| r['fallback_reason'] || 'missing' }.tally.sort.to_h,
                'decisions' => rows,
                'errors' => errors
              }
            end

            def compare(full, v3)
              by_index = v3.to_h { |row| [row['index'], row] }
              transitions = Hash.new(0)
              suppressed = []
              kept = []
              volumes = []
              full.each do |base|
                live = by_index[base['index']]
                unless live
                  suppressed << base if base['status'] == 'suppressed'
                  kept << base if base['status'] == 'kept'
                  next
                end
                raise "Identity mismatch at #{base['index']}" unless
                  base.values_at('code', 'cells') == live.values_at('code', 'cells')

                transitions["#{base['status']}->#{live['status']}"] += 1
                suppressed << [base, live] if
                  base['status'] == 'suppressed' && live['status'] != 'suppressed'
                kept << [base, live] if
                  base['status'] == 'kept' && live['status'] != 'kept'
                volumes << [base, live] if
                  base['status'] == 'kept' && live['status'] == 'kept' &&
                  !same_volume?(base['volume'], live['volume'])
              end
              {
                'pair_count_match' => full.length == v3.length,
                'transition_counts' => transitions.sort.to_h,
                'suppressed_regression_count' => suppressed.length,
                'kept_regression_count' => kept.length,
                'kept_volume_mismatch_count' => volumes.length,
                'inconclusive_to_suppressed_count' =>
                  transitions.fetch('inconclusive->suppressed', 0),
                'suppressed_regressions' => suppressed,
                'kept_regressions' => kept,
                'kept_volume_mismatches' => volumes
              }
            end

            def same_volume?(a, b)
              return true if a.nil? && b.nil?
              return false if a.nil? || b.nil?

              tolerance = [a.to_f.abs, b.to_f.abs, 1.0].max * 1.0e-6
              (a.to_f - b.to_f).abs <= tolerance
            end

            def value(hash, key)
              hash[key] || hash[key.to_sym]
            end

            def sanitize(value)
              value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
            end

            def write(io, payload)
              io.write(JSON.generate(payload))
              io.write("\n")
              io.flush
            end

            def elapsed(started)
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
