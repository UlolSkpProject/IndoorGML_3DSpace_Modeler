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
        # Development-only acceptance benchmark for the canonical rechecker.
        # It executes the internal full-geometry confirmation engine and the
        # production clipped-mesh rechecker over the exact same captured request
        # sequence, then enforces status, volume, and component-count gates.
        module Val3dityRecheckIntegrationBenchmark
          class << self
            attr_reader :last_result_path, :last_progress_log_path, :last_result

            def run_snapshot(name_or_path = nil, report_name: nil, indoor_model: nil)
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

              input_preflight = validate_snapshot_against_current_model!(
                directory,
                request_path,
                requests,
                model_context
              )

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              output_directory = File.join(
                directory,
                'integration_benchmark',
                stamp
              )
              FileUtils.mkdir_p(output_directory)
              name = sanitize(
                report_name || "full_confirmation_vs_canonical_#{stamp}"
              )
              @last_result_path = File.join(output_directory, "#{name}.json")
              @last_progress_log_path = File.join(output_directory, 'progress.jsonl')

              full = nil
              canonical = nil
              File.open(@last_progress_log_path, 'w:UTF-8') do |io|
                io.sync = true
                write(io, event: 'start', request_count: requests.length)
                full = execute(requests, model_context, :full_confirmation, io)
                canonical = execute(requests, model_context, :canonical, io)
              end

              comparison = compare(
                full.fetch('decisions'),
                canonical.fetch('decisions')
              )
              completed = [full, canonical].all? do |run|
                run['processed_request_count'].to_i == requests.length &&
                  Array(run['errors']).empty?
              end
              primary_path_count = canonical.dig(
                'path_counts', 'clipped_mesh_recheck'
              ).to_i
              primary_path_exercised = primary_path_count.positive?
              final_pass = completed &&
                           input_preflight['valid'] == true &&
                           primary_path_exercised &&
                           comparison.values_at(
                             'suppressed_regression_count',
                             'kept_regression_count',
                             'kept_volume_mismatch_count',
                             'kept_component_mismatch_count'
                           ).all?(&:zero?)

              full_ms = full['elapsed_ms'].to_f
              canonical_ms = canonical['elapsed_ms'].to_f
              result = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'mode' => 'full_confirmation_vs_canonical_clipped_mesh_recheck',
                'production_decision_modified' => false,
                'validation_report_modified' => false,
                'source_snapshot_directory' => directory,
                'request_path' => request_path,
                'request_sha256' => Digest::SHA256.file(request_path).hexdigest,
                'request_count' => requests.length,
                'input_preflight' => input_preflight,
                'full_confirmation' => full,
                'canonical' => canonical,
                'comparison' => comparison,
                'timing' => {
                  'full_confirmation_elapsed_ms' => full_ms.round(3),
                  'canonical_elapsed_ms' => canonical_ms.round(3),
                  'speedup_vs_full_confirmation' =>
                    canonical_ms.positive? ?
                      (full_ms / canonical_ms).round(3) : nil,
                  'reduction_percent' =>
                    full_ms.positive? ?
                      (((full_ms - canonical_ms) / full_ms) * 100.0).round(3) : nil
                },
                'primary_path_exercised' => primary_path_exercised,
                'completed' => completed,
                'final_pass' => final_pass
              }
              File.write(
                @last_result_path,
                JSON.pretty_generate(result),
                encoding: 'UTF-8'
              )
              File.open(@last_progress_log_path, 'a:UTF-8') do |io|
                write(
                  io,
                  event: 'finish',
                  final_pass: final_pass,
                  comparison: comparison
                )
              end
              @last_result = result
            end

            def print_report(result = @last_result)
              raise 'No benchmark result is available.' unless result

              comparison = result.fetch('comparison')
              puts
              puts('=' * 112)
              puts('FULL CONFIRMATION vs CANONICAL CLIPPED-MESH RECHECK')
              puts('=' * 112)
              puts "request_count                    : #{result['request_count']}"
              puts "input_valid                      : #{result.dig('input_preflight', 'valid')}"
              puts "resolved_unique_cell_count       : #{result.dig('input_preflight', 'resolved_unique_cell_count')}"
              puts "full_status_counts               : #{result.dig('full_confirmation', 'status_counts')}"
              puts "canonical_status_counts          : #{result.dig('canonical', 'status_counts')}"
              puts "transition_counts                : #{comparison['transition_counts']}"
              puts "suppressed_regression_count      : #{comparison['suppressed_regression_count']}"
              puts "kept_regression_count            : #{comparison['kept_regression_count']}"
              puts "kept_volume_mismatch_count       : #{comparison['kept_volume_mismatch_count']}"
              puts "kept_component_mismatch_count    : #{comparison['kept_component_mismatch_count']}"
              puts "inconclusive_to_suppressed_count : #{comparison['inconclusive_to_suppressed_count']}"
              puts "canonical_path_counts            : #{result.dig('canonical', 'path_counts')}"
              puts "confirmation_reason_counts       : #{result.dig('canonical', 'fallback_reason_counts')}"
              puts "primary_path_exercised           : #{result['primary_path_exercised']}"
              puts "full_elapsed_ms                  : #{result.dig('timing', 'full_confirmation_elapsed_ms')}"
              puts "canonical_elapsed_ms             : #{result.dig('timing', 'canonical_elapsed_ms')}"
              puts "speedup_vs_full                  : #{result.dig('timing', 'speedup_vs_full_confirmation')}"
              puts "reduction_percent                : #{result.dig('timing', 'reduction_percent')}"
              puts "completed                        : #{result['completed']}"
              puts "FINAL PASS                       : #{result['final_pass']}"
              puts "result_path                      : #{@last_result_path}"
              puts "progress_path                    : #{@last_progress_log_path}"
              puts('=' * 112)
              result
            end

            private

            def validate_snapshot_against_current_model!(
              directory,
              request_path,
              requests,
              indoor_model
            )
              checker = Val3dityFullIntersectionRechecker.new(
                indoor_model: indoor_model,
                model: indoor_model.model,
                tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
                logger: nil
              )
              requested_ids = requests.flat_map do |request|
                Array(request['cells']).map(&:to_s)
              end.reject(&:empty?).uniq.sort

              rows = requested_ids.map do |cell_id|
                geometry = checker.send(:model_cell_geometry, cell_id)
                {
                  'cell_id' => cell_id,
                  'status' => geometry[:status].to_s,
                  'reason' => geometry[:reason]&.to_s
                }
              rescue StandardError => e
                {
                  'cell_id' => cell_id,
                  'status' => 'error',
                  'reason' => "#{e.class}: #{e.message}"
                }
              end
              failures = rows.reject { |row| row['status'] == 'ok' }

              metadata_path = File.join(directory, 'snapshot.json')
              metadata = if File.file?(metadata_path)
                           JSON.parse(
                             File.read(metadata_path, encoding: 'UTF-8')
                           )
                         else
                           {}
                         end
              preflight = {
                'request_path' => request_path,
                'request_count' => requests.length,
                'requested_unique_cell_count' => requested_ids.length,
                'resolved_unique_cell_count' => rows.length - failures.length,
                'unresolved_unique_cell_count' => failures.length,
                'resolution_status_counts' =>
                  rows.map { |row| row['status'] }.tally.sort.to_h,
                'failure_reason_prefix_counts' =>
                  failures.map do |row|
                    row['reason'].to_s.split(':', 2).first
                  end.tally.sort.to_h,
                'failure_samples' => failures.first(20),
                'snapshot_model_path' => metadata['model_path'],
                'snapshot_model_title' => metadata['model_title'],
                'current_model_path' => empty_to_nil(indoor_model.model.path),
                'current_model_title' => empty_to_nil(indoor_model.model.title),
                'valid' => failures.empty?
              }
              return preflight if failures.empty?

              details = failures.first(10).map do |row|
                "  #{row['cell_id']}: #{row['reason']}"
              end.join("\n")
              raise RuntimeError,
                    "Recheck snapshot does not match the current IndoorModel.\n" \
                    "resolved=#{preflight['resolved_unique_cell_count']} / " \
                    "#{preflight['requested_unique_cell_count']} unique CellSpaces\n" \
                    "Capture a fresh snapshot and replay it in the same model session.\n" \
                    "Examples:\n#{details}"
            end

            def execute(requests, model, kind, io)
              runner = Val3dityRunner.new(
                File.join(File.dirname(@last_result_path), "__#{kind}.gml"),
                report_name: kind.to_s,
                work_dir: File.dirname(@last_result_path),
                indoor_model: model
              )
              checker_class = kind == :canonical ?
                Val3dityOverlapGeometryRechecker :
                Val3dityFullIntersectionRechecker
              checker = checker_class.new(
                indoor_model: model,
                model: model.model,
                tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
                logger: nil
              )
              runner.instance_variable_set(
                :@overlap_geometry_rechecker,
                checker
              )

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
                  'volume_mm3' => value(
                    result,
                    'actual_overlap_volume_mm3'
                  ),
                  'component_count' => value(
                    result,
                    'intersection_component_count'
                  ),
                  'elapsed_ms' => elapsed(pair_started)
                }
                if kind == :canonical && checker.respond_to?(:proxy_record)
                  row['recheck_path'] = checker.proxy_record(
                    *request['cells']
                  )
                end
                rows << row
                counts[row['status']] += 1
                write(
                  io,
                  event: 'pair',
                  pipeline: kind,
                  index: index,
                  status: row['status']
                )
              rescue StandardError => e
                counts['error'] += 1
                errors << {
                  'index' => index,
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'error' => "#{e.class}: #{e.message}"
                }
              end

              records = kind == :canonical &&
                        checker.respond_to?(:proxy_records) ?
                          checker.proxy_records.values : []
              confirmations = records.select do |row|
                row['path'] == 'full_geometry_confirmation'
              end
              {
                'elapsed_ms' => elapsed(started),
                'processed_request_count' => rows.length + errors.length,
                'status_counts' => counts.sort.to_h,
                'path_counts' => records.map do |row|
                  row['path'] || 'missing'
                end.tally.sort.to_h,
                'fallback_reason_counts' => confirmations.map do |row|
                  row['fallback_reason'] || 'missing'
                end.tally.sort.to_h,
                'decisions' => rows,
                'errors' => errors
              }
            end

            def compare(full, canonical)
              by_index = canonical.to_h { |row| [row['index'], row] }
              transitions = Hash.new(0)
              suppressed = []
              kept = []
              volumes = []
              components = []

              full.each do |base|
                live = by_index[base['index']]
                unless live
                  suppressed << base if base['status'] == 'suppressed'
                  kept << base if base['status'] == 'kept'
                  next
                end
                unless base.values_at('code', 'cells') ==
                       live.values_at('code', 'cells')
                  raise "Identity mismatch at #{base['index']}"
                end

                transitions["#{base['status']}->#{live['status']}"] += 1
                suppressed << [base, live] if
                  base['status'] == 'suppressed' &&
                  live['status'] != 'suppressed'
                kept << [base, live] if
                  base['status'] == 'kept' && live['status'] != 'kept'

                next unless
                  base['status'] == 'kept' && live['status'] == 'kept'

                volumes << [base, live] unless same_volume?(
                  base['volume_mm3'], live['volume_mm3']
                )
                components << [base, live] unless
                  base['component_count'].to_i ==
                  live['component_count'].to_i
              end

              {
                'pair_count_match' => full.length == canonical.length,
                'transition_counts' => transitions.sort.to_h,
                'suppressed_regression_count' => suppressed.length,
                'kept_regression_count' => kept.length,
                'kept_volume_mismatch_count' => volumes.length,
                'kept_component_mismatch_count' => components.length,
                'inconclusive_to_suppressed_count' =>
                  transitions.fetch('inconclusive->suppressed', 0),
                'suppressed_regressions' => suppressed,
                'kept_regressions' => kept,
                'kept_volume_mismatches' => volumes,
                'kept_component_mismatches' => components
              }
            end

            def same_volume?(left, right)
              return false if left.nil? || right.nil?

              tolerance = [
                left.to_f.abs,
                right.to_f.abs,
                1.0
              ].max * 1.0e-6
              (left.to_f - right.to_f).abs <= tolerance
            end

            def value(hash, key)
              return hash[key] if hash.key?(key)

              symbol = key.to_sym
              hash.key?(symbol) ? hash[symbol] : nil
            end

            def empty_to_nil(value)
              text = value.to_s
              text.empty? ? nil : text
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
