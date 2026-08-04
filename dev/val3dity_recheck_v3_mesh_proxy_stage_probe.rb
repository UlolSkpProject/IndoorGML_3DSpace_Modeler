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
        # Dev-only single-pair stage probe for the v3 direct mesh proxy.
        # It writes append-only JSONL stage records and never modifies production code.
        module Val3dityRecheckV3MeshProxyStageProbe
          MODE = 'recheck_only_v3_direct_mesh_proxy_stage_probe'

          class StageAnalyzer < Val3dityRecheckV3MeshProxy::RebuildAnalyzer
            def initialize(tolerance, stage_callback)
              super(tolerance)
              @stage_callback = stage_callback
            end

            def analyze_rebuild(group1, group2, cell_ids, cache)
              emit_stage('analysis_start', 'cells' => cell_ids.map(&:to_s))
              started = stage_clock
              result = super
              report = result[:report] || {}
              emit_stage(
                'analysis_complete',
                'elapsed_ms' => stage_elapsed_ms(started),
                'status' => report['status'],
                'error' => report['error'],
                'source_cell' => report['source_cell'],
                'target_cell' => report['target_cell'],
                'candidate_triangle_count' => report['candidate_triangle_count'],
                'raw_triangle_count' => report['reconstructed_raw_triangle_count'],
                'total_triangle_count' => report['reconstructed_total_triangle_count'],
                'topology' => report['reconstructed_topology']
              )
              result
            rescue StandardError => e
              emit_stage(
                'analysis_exception',
                'elapsed_ms' => stage_elapsed_ms(started),
                'error' => "#{e.class}: #{e.message}"
              )
              raise
            end

            private

            def conforming_triangle_soup(triangles)
              emit_stage(
                'conforming_start',
                'input_triangle_count' => triangles.length,
                'input_vertex_occurrence_count' => triangles.length * 3
              )
              started = stage_clock
              result = super
              emit_stage(
                'conforming_complete',
                'elapsed_ms' => stage_elapsed_ms(started),
                'output_triangle_count' => result.length
              )
              result
            rescue StandardError => e
              emit_stage(
                'conforming_exception',
                'elapsed_ms' => stage_elapsed_ms(started),
                'error' => "#{e.class}: #{e.message}"
              )
              raise
            end

            def build_cap_triangles(plane_segments, crop, mesh)
              emit_stage(
                'cap_build_start',
                'plane_segment_counts' => plane_segments.transform_values(&:length)
              )
              started = stage_clock
              result = super
              emit_stage(
                'cap_build_complete',
                'elapsed_ms' => stage_elapsed_ms(started),
                'error' => result[:error],
                'triangle_count' => Array(result[:triangles]).length,
                'report' => result[:report]
              )
              result
            rescue StandardError => e
              emit_stage(
                'cap_build_exception',
                'elapsed_ms' => stage_elapsed_ms(started),
                'error' => "#{e.class}: #{e.message}"
              )
              raise
            end

            def emit_stage(event, payload = {})
              @stage_callback&.call(event, payload)
            rescue StandardError
              nil
            end

            def stage_elapsed_ms(started)
              ((stage_clock - started) * 1000.0).round(3)
            end

            def stage_clock
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end

          class StageRechecker < Val3dityRecheckV3MeshProxy::Rechecker
            def initialize(stage_callback:, **options)
              @stage_callback = stage_callback
              super(**options)
              @rebuild_analyzer = StageAnalyzer.new(
                options.fetch(:tolerance),
                stage_callback
              )
            end

            private

            def model_solid_intersection_for_pair(group1, group2, cell_id1, cell_id2)
              emit_stage(
                'pair_geometry_start',
                'cells' => [cell_id1.to_s, cell_id2.to_s]
              )
              started = stage_clock
              result = super
              emit_stage(
                'pair_geometry_complete',
                'elapsed_ms' => stage_elapsed_ms(started),
                'status' => result.is_a?(Hash) ? result[:status].to_s : nil,
                'reason' => result.is_a?(Hash) ? result[:reason].to_s : nil
              )
              result
            rescue StandardError => e
              emit_stage(
                'pair_geometry_exception',
                'elapsed_ms' => stage_elapsed_ms(started),
                'error' => "#{e.class}: #{e.message}"
              )
              raise
            end

            def direct_proxy_intersection(source, target, cell_ids, geometry, record)
              emit_stage(
                'proxy_operation_start',
                'cells' => cell_ids,
                'triangle_count' => Array(geometry[:triangles]).length
              )

              model = @model || Sketchup.active_model
              return stage_fallback('model_unavailable') unless model
              return stage_fallback('input_not_manifold') unless
                valid_manifold_group?(source) && valid_manifold_group?(target)

              proxy = nil
              target_copy = nil
              result = nil
              outcome = @indoor_model.with_indoor_model_operation(
                'IndoorGML v3 direct mesh proxy stage probe', rollback: true
              ) do
                proxy_started = stage_clock
                emit_stage(
                  'proxy_build_start',
                  'triangle_count' => Array(geometry[:triangles]).length
                )
                proxy = build_proxy_group(source, geometry.fetch(:triangles))
                record['proxy_build_elapsed_ms'] = stage_elapsed_ms(proxy_started)
                emit_stage(
                  'proxy_build_complete',
                  'elapsed_ms' => record['proxy_build_elapsed_ms'],
                  'created' => !proxy.nil?
                )
                next stage_fallback('proxy_build_failed') unless proxy

                record['proxy_face_count'] = valid_faces(proxy).length
                record['proxy_edge_count'] = valid_edges(proxy).length
                record['proxy_surface_triangle_count'] = geometry[:clipped_surface_triangle_count]
                record['proxy_cap_triangle_count'] = geometry[:cap_triangle_count]
                proxy_manifold = valid_manifold_group?(proxy)
                emit_stage(
                  'proxy_manifold_check',
                  'manifold' => proxy_manifold,
                  'face_count' => record['proxy_face_count'],
                  'edge_count' => record['proxy_edge_count']
                )
                next stage_fallback('proxy_not_manifold') unless proxy_manifold

                proxy_volume = solid_group_volume(proxy)
                emit_stage('proxy_volume_check', 'volume_in3' => proxy_volume)
                next stage_fallback('proxy_nonpositive_volume') unless proxy_volume&.positive?
                record['proxy_volume_in3'] = proxy_volume

                target_started = stage_clock
                emit_stage('target_copy_start')
                target_copy = build_boolean_copy(target)
                record['target_copy_elapsed_ms'] = stage_elapsed_ms(target_started)
                emit_stage(
                  'target_copy_complete',
                  'elapsed_ms' => record['target_copy_elapsed_ms'],
                  'created' => !target_copy.nil?
                )
                next stage_fallback('target_copy_failed') unless target_copy

                target_manifold = valid_manifold_group?(target_copy)
                emit_stage('target_copy_manifold_check', 'manifold' => target_manifold)
                next stage_fallback('target_copy_not_manifold') unless target_manifold
                next stage_fallback('target_boolean_unsupported') unless proxy.respond_to?(:intersect)

                boolean_started = stage_clock
                emit_stage(
                  'target_boolean_start',
                  'proxy_face_count' => record['proxy_face_count'],
                  'target_face_count' => valid_faces(target_copy).length
                )
                result = proxy.intersect(target_copy)
                record['target_boolean_elapsed_ms'] = stage_elapsed_ms(boolean_started)
                emit_stage(
                  'target_boolean_complete',
                  'elapsed_ms' => record['target_boolean_elapsed_ms'],
                  'result_nil' => result.nil?
                )
                next stage_fallback('target_boolean_failed') if result.nil?

                classified = classify_proxy_result(result, cell_ids)
                emit_stage(
                  'classification_complete',
                  'status' => classified[:status].to_s,
                  'reason' => classified[:reason].to_s,
                  'volume' => classified[:volume],
                  'component_count' => classified[:component_count]
                )
                classified
              end
              outcome
            rescue StandardError => e
              record['proxy_operation_exception'] = "#{e.class}: #{e.message}"
              emit_stage(
                'proxy_operation_exception',
                'error' => record['proxy_operation_exception']
              )
              stage_fallback('proxy_operation_exception')
            ensure
              cleanup_entities(result, target_copy, proxy, source, target)
              emit_stage('proxy_operation_cleanup_complete')
            end

            # The inherited helper previously called `super` from inside
            # original_fallback, which searches for a superclass implementation
            # of original_fallback. There is none. Explicitly invoke the parent
            # implementation of model_solid_intersection_for_pair instead.
            def original_fallback(record, group1, group2, cell_id1, cell_id2, reason, started)
              fallback_started = stage_clock
              emit_stage(
                'original_fallback_start',
                'reason' => reason.to_s,
                'cells' => [cell_id1.to_s, cell_id2.to_s]
              )
              base_method = Val3dityOverlapGeometryRechecker.instance_method(
                :model_solid_intersection_for_pair
              )
              result = base_method.bind(self).call(
                group1, group2, cell_id1, cell_id2
              )
              record['path'] = 'original_full_recheck_fallback'
              record['fallback_reason'] = reason.to_s
              record['fallback_elapsed_ms'] = stage_elapsed_ms(fallback_started)
              record['intersection_status'] = result[:status].to_s if result.is_a?(Hash)
              record['intersection_reason'] = result[:reason].to_s if
                result.is_a?(Hash) && result[:reason]
              record['intersection_volume_in3'] = result[:volume] if
                result.is_a?(Hash) && result.key?(:volume)
              record['intersection_component_count'] = result[:component_count] if
                result.is_a?(Hash) && result.key?(:component_count)
              record['total_elapsed_ms'] = stage_elapsed_ms(started)
              store_record(record)
              emit_stage(
                'original_fallback_complete',
                'elapsed_ms' => record['fallback_elapsed_ms'],
                'status' => result.is_a?(Hash) ? result[:status].to_s : nil,
                'reason' => result.is_a?(Hash) ? result[:reason].to_s : nil
              )
              result
            rescue StandardError => e
              record['fallback_exception'] = "#{e.class}: #{e.message}"
              record['path'] = 'original_full_recheck_fallback_error'
              record['fallback_reason'] = reason.to_s
              record['fallback_elapsed_ms'] = stage_elapsed_ms(fallback_started)
              record['total_elapsed_ms'] = stage_elapsed_ms(started)
              store_record(record)
              emit_stage(
                'original_fallback_exception',
                'elapsed_ms' => record['fallback_elapsed_ms'],
                'error' => record['fallback_exception']
              )
              raise
            end

            def stage_fallback(reason)
              emit_stage('proxy_fallback_requested', 'reason' => reason.to_s)
              fallback_result(reason)
            end

            def emit_stage(event, payload = {})
              @stage_callback&.call(event, payload)
            rescue StandardError
              nil
            end

            def stage_elapsed_ms(started)
              ((stage_clock - started) * 1000.0).round(3)
            end

            def stage_clock
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end

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
                callback = lambda do |event, payload|
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
                rechecker = StageRechecker.new(
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
