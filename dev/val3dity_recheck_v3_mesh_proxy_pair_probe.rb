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
        # Dev-only single-pair stage probe for the direct v3 mesh proxy path.
        #
        # analysis mode never enters SketchUp Boolean. full mode executes the
        # unchanged final proxy-versus-target Boolean while appending stage
        # events before and after every expensive operation.
        module Val3dityRecheckV3MeshProxyPairProbe
          MODE = 'v3_direct_mesh_proxy_single_pair_stage_probe'
          THREAD_TRACER_KEY = :indoor_gml_v3_mesh_proxy_stage_tracer

          class StageTracer
            attr_reader :path

            def initialize(path, cells:, request_index:, mode:)
              @path = path
              @cells = cells.map(&:to_s)
              @request_index = request_index.to_i
              @mode = mode.to_s
              @started = clock
              @io = File.open(path, 'a:UTF-8')
              @io.sync = true
            end

            def emit(event, payload = {})
              row = {
                'event' => event.to_s,
                'generated_at' => Time.now.iso8601(6),
                'elapsed_seconds' => (clock - @started).round(6),
                'request_index' => @request_index,
                'cells' => @cells,
                'probe_mode' => @mode
              }.merge(stringify(payload))
              @io.puts(JSON.generate(row))
              @io.flush
              row
            rescue StandardError
              nil
            end

            def close
              @io&.close unless @io&.closed?
            rescue StandardError
              nil
            end

            private

            def clock
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end

            def stringify(value)
              case value
              when Hash
                value.each_with_object({}) do |(key, item), result|
                  result[key.to_s] = stringify(item)
                end
              when Array
                value.map { |item| stringify(item) }
              when Symbol
                value.to_s
              else
                value
              end
            end
          end

          module AnalyzerStageTrace
            private

            def conforming_triangle_soup(triangles)
              tracer = Thread.current[THREAD_TRACER_KEY]
              started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              tracer&.emit('conforming_start', {
                'raw_triangle_count' => triangles.length,
                'raw_vertex_occurrence_count' => triangles.length * 3
              })
              result = super
              tracer&.emit('conforming_complete', {
                'elapsed_ms' => elapsed_probe_ms(started),
                'output_triangle_count' => result.length,
                'output_vertex_occurrence_count' => result.length * 3
              })
              result
            rescue StandardError => e
              tracer&.emit('conforming_error', {
                'elapsed_ms' => elapsed_probe_ms(started),
                'error' => "#{e.class}: #{e.message}"
              })
              raise
            end

            def triangle_soup_topology(triangles)
              tracer = Thread.current[THREAD_TRACER_KEY]
              started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              tracer&.emit('topology_gate_start', {
                'triangle_count' => triangles.length
              })
              result = super
              tracer&.emit('topology_gate_complete', {
                'elapsed_ms' => elapsed_probe_ms(started),
                'topology' => result
              })
              result
            rescue StandardError => e
              tracer&.emit('topology_gate_error', {
                'elapsed_ms' => elapsed_probe_ms(started),
                'error' => "#{e.class}: #{e.message}"
              })
              raise
            end

            def elapsed_probe_ms(started)
              ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0).round(3)
            end
          end

          module RecheckerStageTrace
            private

            def build_proxy_group(source, triangles)
              tracer = Thread.current[THREAD_TRACER_KEY]
              started = clock
              tracer&.emit('proxy_build_start', {
                'triangle_count' => triangles.length
              })
              result = super
              tracer&.emit('proxy_build_complete', {
                'elapsed_ms' => elapsed_ms(started),
                'result_nil' => result.nil?,
                'face_count' => result ? valid_faces(result).length : 0,
                'edge_count' => result ? valid_edges(result).length : 0
              })
              result
            rescue StandardError => e
              tracer&.emit('proxy_build_error', {
                'elapsed_ms' => elapsed_ms(started),
                'error' => "#{e.class}: #{e.message}"
              })
              raise
            end

            def direct_proxy_intersection(source, target, cell_ids, geometry, record)
              tracer = Thread.current[THREAD_TRACER_KEY]
              model = @model || Sketchup.active_model
              return fallback_result('model_unavailable') unless model
              return fallback_result('input_not_manifold') unless
                valid_manifold_group?(source) && valid_manifold_group?(target)

              proxy = nil
              target_copy = nil
              result = nil
              outcome = @indoor_model.with_indoor_model_operation(
                'IndoorGML v3 direct mesh proxy stage probe', rollback: true
              ) do
                proxy_started = clock
                proxy = build_proxy_group(source, geometry.fetch(:triangles))
                record['proxy_build_elapsed_ms'] = elapsed_ms(proxy_started)
                next fallback_result('proxy_build_failed') unless proxy

                record['proxy_face_count'] = valid_faces(proxy).length
                record['proxy_edge_count'] = valid_edges(proxy).length
                record['proxy_surface_triangle_count'] = geometry[:clipped_surface_triangle_count]
                record['proxy_cap_triangle_count'] = geometry[:cap_triangle_count]

                tracer&.emit('proxy_manifold_check_start', {
                  'face_count' => record['proxy_face_count'],
                  'edge_count' => record['proxy_edge_count']
                })
                manifold = valid_manifold_group?(proxy)
                tracer&.emit('proxy_manifold_check_complete', {
                  'manifold' => manifold
                })
                next fallback_result('proxy_not_manifold') unless manifold

                proxy_volume = solid_group_volume(proxy)
                tracer&.emit('proxy_volume_complete', {
                  'volume_in3' => proxy_volume
                })
                next fallback_result('proxy_nonpositive_volume') unless proxy_volume&.positive?
                record['proxy_volume_in3'] = proxy_volume

                target_started = clock
                tracer&.emit('target_copy_start')
                target_copy = build_boolean_copy(target)
                record['target_copy_elapsed_ms'] = elapsed_ms(target_started)
                tracer&.emit('target_copy_complete', {
                  'elapsed_ms' => record['target_copy_elapsed_ms'],
                  'result_nil' => target_copy.nil?
                })
                next fallback_result('target_copy_failed') unless target_copy
                next fallback_result('target_copy_not_manifold') unless valid_manifold_group?(target_copy)
                next fallback_result('target_boolean_unsupported') unless proxy.respond_to?(:intersect)

                boolean_started = clock
                tracer&.emit('target_boolean_start', {
                  'proxy_face_count' => record['proxy_face_count'],
                  'proxy_edge_count' => record['proxy_edge_count'],
                  'target_face_count' => valid_faces(target_copy).length,
                  'target_edge_count' => valid_edges(target_copy).length
                })
                result = proxy.intersect(target_copy)
                record['target_boolean_elapsed_ms'] = elapsed_ms(boolean_started)
                tracer&.emit('target_boolean_complete', {
                  'elapsed_ms' => record['target_boolean_elapsed_ms'],
                  'result_nil' => result.nil?
                })
                next fallback_result('target_boolean_failed') if result.nil?

                tracer&.emit('intersection_classification_start')
                classified = classify_proxy_result(result, cell_ids)
                tracer&.emit('intersection_classification_complete', {
                  'status' => classified[:status],
                  'reason' => classified[:reason],
                  'volume' => classified[:volume],
                  'component_count' => classified[:component_count]
                })
                classified
              end
              outcome
            rescue StandardError => e
              record['proxy_operation_exception'] = "#{e.class}: #{e.message}"
              tracer&.emit('direct_proxy_error', {
                'error' => record['proxy_operation_exception']
              })
              fallback_result('proxy_operation_exception')
            ensure
              cleanup_entities(result, target_copy, proxy, source, target)
            end

            def original_fallback(record, group1, group2, cell_id1, cell_id2, reason, started)
              tracer = Thread.current[THREAD_TRACER_KEY]
              tracer&.emit('original_fallback_start', {
                'fallback_reason' => reason.to_s
              })
              result = super
              tracer&.emit('original_fallback_complete', {
                'path' => record['path'],
                'fallback_elapsed_ms' => record['fallback_elapsed_ms'],
                'intersection_status' => record['intersection_status']
              })
              result
            end
          end

          class << self
            attr_reader :last_result_path, :last_stage_log_path, :last_result

            def run_snapshot_pair(name_or_path = nil, request_index: 19,
                                  mode: :analysis, report_name: nil,
                                  output_dir: nil, indoor_model: nil)
              install_trace_hooks!
              normalized_mode = mode.to_s
              unless %w[analysis full].include?(normalized_mode)
                raise ArgumentError, 'mode must be :analysis or :full'
              end

              store = Val3dityRecheckSnapshotStore
              snapshot_dir = store.resolve_directory(name_or_path)
              request_path = store.request_path(name_or_path)
              raise 'Persistent recheck snapshot was not found.' unless
                snapshot_dir && request_path && File.file?(request_path)

              requests = Val3dityRecheckOnlyRunner.requests_from_file(request_path)
              index = Integer(request_index)
              request = requests[index]
              raise "Request index is out of range: #{index}" unless request

              indoor_model ||= IndoorCore::IndoorModel.current
              raise 'IndoorModel.current is not bound to the active model.' unless
                indoor_model&.model == Sketchup.active_model

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              directory = File.expand_path(
                output_dir || File.join(
                  snapshot_dir, 'benchmarks', 'v3_mesh_proxy_pair_probe', stamp
                )
              )
              FileUtils.mkdir_p(directory)
              name = sanitize(report_name || "pair_#{index}_#{normalized_mode}")
              stage_path = File.join(directory, 'stage.jsonl')
              result_path = File.join(directory, "#{name}.json")
              @last_stage_log_path = stage_path
              @last_result_path = result_path

              tracer = StageTracer.new(
                stage_path,
                cells: request.fetch('cells'),
                request_index: index,
                mode: normalized_mode
              )
              Thread.current[THREAD_TRACER_KEY] = tracer
              tracer.emit('probe_start', {
                'code' => request['code'],
                'request_path' => request_path,
                'result_path' => result_path
              })

              result = if normalized_mode == 'analysis'
                         run_analysis_only(request, indoor_model, tracer)
                       else
                         run_full_pair(request, indoor_model, tracer, result_path)
                       end
              File.write(result_path, JSON.pretty_generate(result), encoding: 'UTF-8')
              tracer.emit('probe_finish', {
                'result_path' => result_path,
                'status' => result['status'],
                'path' => result['path'],
                'fallback_reason' => result['fallback_reason']
              })
              @last_result = result
              result
            rescue StandardError => e
              tracer&.emit('probe_error', {
                'error' => "#{e.class}: #{e.message}"
              })
              raise
            ensure
              Thread.current[THREAD_TRACER_KEY] = nil
              tracer&.close
            end

            private

            def run_analysis_only(request, indoor_model, tracer)
              cells = request.fetch('cells').map(&:to_s)
              group1 = group_for_cell(indoor_model, cells[0])
              group2 = group_for_cell(indoor_model, cells[1])
              analyzer = Val3dityRecheckV3MeshProxy::RebuildAnalyzer.new(
                Utils::Geometry::VALIDATION_TOLERANCE
              )
              tracer.emit('analysis_start')
              started = clock
              analyzed = analyzer.analyze_rebuild(group1, group2, cells, {})
              elapsed = elapsed_ms(started)
              report = analyzed.fetch(:report)
              geometry = analyzed[:geometry]
              tracer.emit('analysis_complete', {
                'elapsed_ms' => elapsed,
                'status' => report['status'],
                'error' => report['error'],
                'source_cell' => report['source_cell'],
                'target_cell' => report['target_cell'],
                'candidate_triangle_count' => report['candidate_triangle_count'],
                'raw_triangle_count' => report['reconstructed_raw_triangle_count'],
                'output_triangle_count' => report['reconstructed_total_triangle_count'],
                'topology' => report['reconstructed_topology']
              })
              {
                'schema_version' => 1,
                'mode' => MODE,
                'probe_mode' => 'analysis',
                'status' => report['status'],
                'path' => geometry ? 'analysis_complete' : 'analysis_failed',
                'fallback_reason' => report['error'],
                'request' => request,
                'analysis_elapsed_ms' => elapsed,
                'analysis' => report,
                'geometry_summary' => geometry && {
                  'triangle_count' => geometry.fetch(:triangles).length,
                  'clipped_surface_triangle_count' => geometry[:clipped_surface_triangle_count],
                  'cap_triangle_count' => geometry[:cap_triangle_count]
                }
              }
            end

            def run_full_pair(request, indoor_model, tracer, result_path)
              runner = Val3dityRunner.new(
                File.join(File.dirname(result_path), '__recheck_only_input__.gml'),
                report_name: File.basename(result_path, '.json'),
                work_dir: File.dirname(result_path),
                indoor_model: indoor_model
              )
              rechecker = Val3dityRecheckV3MeshProxy::Rechecker.new(
                indoor_model: indoor_model,
                model: indoor_model.model,
                tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
                logger: nil
              )
              runner.instance_variable_set(:@overlap_geometry_rechecker, rechecker)

              tracer.emit('pair_recheck_start', { 'code' => request['code'] })
              started = clock
              raw = runner.send(
                :recheck_cell_pair,
                request['code'], request['cells'][0], request['cells'][1]
              )
              elapsed = elapsed_ms(started)
              record = rechecker.proxy_record(request['cells'][0], request['cells'][1])
              tracer.emit('pair_recheck_complete', {
                'elapsed_ms' => elapsed,
                'status' => fetch_value(raw, 'status'),
                'path' => record && record['path'],
                'fallback_reason' => record && record['fallback_reason']
              })
              {
                'schema_version' => 1,
                'mode' => MODE,
                'probe_mode' => 'full',
                'status' => fetch_value(raw, 'status').to_s,
                'path' => record && record['path'],
                'fallback_reason' => record && record['fallback_reason'],
                'request' => request,
                'pair_elapsed_ms' => elapsed,
                'decision' => normalize(raw),
                'proxy' => record
              }
            end

            def group_for_cell(indoor_model, cell_id)
              cell = Array(indoor_model.cell_spaces).find do |candidate|
                candidate_id(candidate) == cell_id.to_s
              end
              raise "CellSpace was not found: #{cell_id}" unless cell

              group = if cell.respond_to?(:valid_sketchup_group)
                        cell.valid_sketchup_group
                      elsif cell.respond_to?(:sketchup_group)
                        cell.sketchup_group
                      elsif cell.respond_to?(:group)
                        cell.group
                      end
              raise "Valid SketchUp group was not found: #{cell_id}" unless
                group&.respond_to?(:valid?) && group.valid?

              group
            end

            def candidate_id(cell)
              %i[id gml_id identifier].each do |method_name|
                next unless cell.respond_to?(method_name)

                value = cell.public_send(method_name)
                return value.to_s unless value.nil?
              end
              ''
            rescue StandardError
              ''
            end

            def install_trace_hooks!
              analyzer = Val3dityRecheckV3MeshProxy::RebuildAnalyzer
              rechecker = Val3dityRecheckV3MeshProxy::Rechecker
              analyzer.prepend(AnalyzerStageTrace) unless analyzer.ancestors.include?(AnalyzerStageTrace)
              rechecker.prepend(RecheckerStageTrace) unless rechecker.ancestors.include?(RecheckerStageTrace)
            end

            def normalize(value)
              case value
              when Hash
                value.each_with_object({}) do |(key, item), result|
                  result[key.to_s] = normalize(item)
                end
              when Array
                value.map { |item| normalize(item) }
              when Symbol
                value.to_s
              else
                value
              end
            end

            def fetch_value(value, key)
              return nil unless value.is_a?(Hash)

              value[key] || value[key.to_sym]
            end

            def sanitize(value)
              result = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              result.empty? ? 'pair_probe' : result
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
