# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

require_relative 'val3dity_recheck_v3_mesh_proxy_stage_probe'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only corrected runner for the stage probe.
        # Reuses StageRechecker and only fixes the callback's optional payload.
        module Val3dityRecheckV3MeshProxyStageProbeRunnerFix
          MODE = 'recheck_only_v3_direct_mesh_proxy_stage_probe'

          class << self
            attr_reader :last_result_path, :last_progress_log_path, :last_result

            def run_snapshot_pair(name_or_path = nil, cell_id1:, cell_id2:,
                                  report_name: nil, output_dir: nil,
                                  indoor_model: nil)
              store = Val3dityRecheckSnapshotStore
              snapshot_dir = store.resolve_directory(name_or_path)
              request_path = store.request_path(name_or_path)
              raise 'Persistent recheck snapshot was not found.' unless
                snapshot_dir && request_path && File.file?(request_path)

              requests = Val3dityRecheckOnlyRunner.requests_from_file(request_path)
              request = requests.find do |row|
                Array(row['cells']).map(&:to_s).sort ==
                  [cell_id1.to_s, cell_id2.to_s].sort
              end
              raise "Requested cell pair was not found: #{cell_id1} <-> #{cell_id2}" unless request

              indoor_model ||= IndoorCore::IndoorModel.current
              raise 'IndoorModel.current is not bound to the active model.' unless
                indoor_model&.model == Sketchup.active_model

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              name = sanitize(report_name || "v3_mesh_proxy_stage_#{stamp}")
              directory = File.expand_path(
                output_dir || File.join(
                  snapshot_dir, 'benchmarks', 'v3_mesh_proxy_stage', stamp
                )
              )
              FileUtils.mkdir_p(directory)
              progress_path = File.join(directory, 'progress.jsonl')
              result_path = File.join(directory, "#{name}.json")
              @last_progress_log_path = progress_path
              @last_result_path = result_path

              started = stage_clock
              result_payload = nil
              File.open(progress_path, 'a:UTF-8') do |io|
                io.sync = true
                callback = lambda do |event, payload = {}|
                  append_progress(io, {
                    'event' => event,
                    'generated_at' => Time.now.iso8601(6),
                    'elapsed_seconds' => (stage_clock - started).round(6),
                    'cells' => request['cells']
                  }.merge(payload || {}))
                end

                callback.call('start', {
                  'mode' => MODE,
                  'code' => request['code'],
                  'request_path' => request_path
                })

                runner = Val3dityRunner.new(
                  File.join(directory, '__recheck_only_input__.gml'),
                  report_name: name,
                  work_dir: directory,
                  indoor_model: indoor_model
                )
                rechecker = Val3dityRecheckV3MeshProxyStageProbe::StageRechecker.new(
                  stage_callback: callback,
                  indoor_model: indoor_model,
                  model: indoor_model.model,
                  tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
                  logger: nil
                )
                runner.instance_variable_set(:@overlap_geometry_rechecker, rechecker)

                callback.call('recheck_cell_pair_start')
                pair_started = stage_clock
                decision = runner.send(
                  :recheck_cell_pair,
                  request['code'], request['cells'][0], request['cells'][1]
                )
                pair_elapsed_ms = stage_elapsed_ms(pair_started)
                callback.call('recheck_cell_pair_complete', {
                  'pair_elapsed_ms' => pair_elapsed_ms,
                  'status' => fetch_value(decision, 'status').to_s,
                  'reason' => fetch_value(decision, 'reason').to_s
                })

                record = rechecker.proxy_record(
                  request['cells'][0], request['cells'][1]
                )
                result_payload = {
                  'schema_version' => 1,
                  'generated_at' => Time.now.iso8601(6),
                  'mode' => MODE,
                  'production_code_modified' => false,
                  'source_crop_boolean_used' => false,
                  'target_boolean_used' => true,
                  'request_path' => request_path,
                  'request' => request,
                  'elapsed_ms' => stage_elapsed_ms(started),
                  'pair_elapsed_ms' => pair_elapsed_ms,
                  'decision' => decision,
                  'proxy' => record,
                  'progress_log_path' => progress_path
                }
                File.write(
                  result_path,
                  JSON.pretty_generate(result_payload),
                  encoding: 'UTF-8'
                )
                callback.call('finish', {
                  'result_path' => result_path,
                  'elapsed_ms' => result_payload['elapsed_ms']
                })
              rescue StandardError => e
                error_payload = {
                  'schema_version' => 1,
                  'generated_at' => Time.now.iso8601(6),
                  'mode' => MODE,
                  'production_code_modified' => false,
                  'request_path' => request_path,
                  'request' => request,
                  'elapsed_ms' => stage_elapsed_ms(started),
                  'error' => "#{e.class}: #{e.message}",
                  'backtrace' => Array(e.backtrace).first(20),
                  'progress_log_path' => progress_path
                }
                File.write(
                  result_path,
                  JSON.pretty_generate(error_payload),
                  encoding: 'UTF-8'
                )
                append_progress(io, {
                  'event' => 'fatal_error',
                  'generated_at' => Time.now.iso8601(6),
                  'elapsed_seconds' => (stage_clock - started).round(6),
                  'cells' => request['cells'],
                  'error' => error_payload['error'],
                  'result_path' => result_path
                })
                result_payload = error_payload
              end

              @last_result = result_payload
              result_payload
            end

            private

            def append_progress(io, payload)
              io.write(JSON.generate(payload))
              io.write("\n")
              io.flush
            end

            def fetch_value(hash, key)
              return nil unless hash.is_a?(Hash)

              hash[key] || hash[key.to_sym]
            end

            def sanitize(value)
              text = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              text.empty? ? 'v3_mesh_proxy_stage' : text
            end

            def stage_elapsed_ms(started)
              ((stage_clock - started) * 1000.0).round(3)
            end

            def stage_clock
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end
        end
      end
    end
  end
end
