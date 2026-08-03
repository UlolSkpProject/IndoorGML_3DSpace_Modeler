# frozen_string_literal: true

require 'json'
require 'time'

require_relative '../indoor3d/validity/val3dity_runner'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckBenchmarkProbe
          SCHEMA_VERSION = 1
          THREAD_RECORDER_KEY = :indoor_gml_val3dity_recheck_benchmark_recorder

          class Recorder
            attr_reader :started_at

            def initialize(metadata = {})
              @metadata = metadata
              @started_at = Time.now
              @monotonic_started_at = monotonic_now
              @timings = {}
              @counters = Hash.new(0)
              @pairs = {}
              @pair_stack = []
              @gc_before = gc_snapshot
            end

            def measure(stage)
              started = monotonic_now
              allocations_before = allocated_objects
              result = yield
              result
            ensure
              elapsed_ms = (monotonic_now - started) * 1000.0
              allocations = allocated_objects - allocations_before
              record_timing(stage, elapsed_ms, allocations)
            end

            def increment(name, amount = 1)
              value = amount.to_i
              @counters[name.to_s] += value
              current_pair[:counters][name.to_s] += value if current_pair
            end

            def observe(name, value)
              return if value.nil?

              @metadata[name.to_s] = value
              current_pair[:observations][name.to_s] = value if current_pair
            end

            def with_pair(cell_id1, cell_id2)
              key = [cell_id1.to_s, cell_id2.to_s].sort.join('|')
              pair = (@pairs[key] ||= new_pair_record(key))
              @pair_stack << pair
              yield(pair)
            ensure
              @pair_stack.pop
            end

            def current_pair
              @pair_stack.last
            end

            def record_pair_result(result)
              return unless current_pair && result.is_a?(Hash)

              current_pair[:status] = result[:status].to_s if result.key?(:status)
              current_pair[:reason] = result[:reason].to_s if result[:reason]
              current_pair[:candidate_count] = Array(result[:adjacency_candidates]).length if result.key?(:adjacency_candidates)
              intersection = result[:intersection]
              if intersection.is_a?(Hash)
                current_pair[:intersection_status] = intersection[:status].to_s
                current_pair[:intersection_reason] = intersection[:reason].to_s if intersection[:reason]
                current_pair[:intersection_volume_in3] = intersection[:volume]
                current_pair[:intersection_component_count] = intersection[:component_count]
              end
            end

            def snapshot
              finished_at = Time.now
              elapsed_ms = (monotonic_now - @monotonic_started_at) * 1000.0
              gc_after = gc_snapshot

              {
                'schema_version' => SCHEMA_VERSION,
                'generated_at' => finished_at.iso8601(6),
                'started_at' => @started_at.iso8601(6),
                'elapsed_ms' => elapsed_ms.round(3),
                'runtime' => runtime_metadata,
                'metadata' => @metadata,
                'counters' => sorted_hash(@counters),
                'timings' => timing_snapshot(@timings),
                'pairs' => pair_snapshot,
                'gc_delta' => numeric_delta(@gc_before, gc_after),
                'hotspots' => timing_snapshot(@timings)
                  .sort_by { |_stage, row| -row['total_ms'].to_f }
                  .first(15)
                  .map { |stage, row| row.merge('stage' => stage) }
              }
            end

            private

            def record_timing(stage, elapsed_ms, allocations)
              key = stage.to_s
              row = (@timings[key] ||= {
                count: 0,
                total_ms: 0.0,
                min_ms: nil,
                max_ms: nil,
                allocations: 0
              })
              row[:count] += 1
              row[:total_ms] += elapsed_ms
              row[:min_ms] = elapsed_ms if row[:min_ms].nil? || elapsed_ms < row[:min_ms]
              row[:max_ms] = elapsed_ms if row[:max_ms].nil? || elapsed_ms > row[:max_ms]
              row[:allocations] += allocations

              pair = current_pair
              return unless pair

              pair_row = (pair[:timings][key] ||= {
                count: 0,
                total_ms: 0.0,
                max_ms: nil,
                allocations: 0
              })
              pair_row[:count] += 1
              pair_row[:total_ms] += elapsed_ms
              pair_row[:max_ms] = elapsed_ms if pair_row[:max_ms].nil? || elapsed_ms > pair_row[:max_ms]
              pair_row[:allocations] += allocations
            end

            def new_pair_record(key)
              {
                key: key,
                counters: Hash.new(0),
                observations: {},
                timings: {},
                status: nil,
                reason: nil,
                candidate_count: nil,
                intersection_status: nil,
                intersection_reason: nil,
                intersection_volume_in3: nil,
                intersection_component_count: nil
              }
            end

            def pair_snapshot
              @pairs.values.map do |pair|
                pair_total = pair[:timings].fetch('rechecker.analyze_pair', {})[:total_ms].to_f
                {
                  'cells' => pair[:key].split('|', 2),
                  'total_ms' => pair_total.round(3),
                  'status' => pair[:status],
                  'reason' => pair[:reason],
                  'candidate_count' => pair[:candidate_count],
                  'intersection_status' => pair[:intersection_status],
                  'intersection_reason' => pair[:intersection_reason],
                  'intersection_volume_in3' => pair[:intersection_volume_in3],
                  'intersection_component_count' => pair[:intersection_component_count],
                  'observations' => sorted_hash(pair[:observations]),
                  'counters' => sorted_hash(pair[:counters]),
                  'timings' => timing_snapshot(pair[:timings])
                }
              end.sort_by { |pair| -pair['total_ms'].to_f }
            end

            def timing_snapshot(source)
              source.keys.sort.each_with_object({}) do |key, result|
                row = source[key]
                count = row[:count].to_i
                total = row[:total_ms].to_f
                result[key] = {
                  'count' => count,
                  'total_ms' => total.round(3),
                  'average_ms' => (count.zero? ? 0.0 : total / count).round(3),
                  'min_ms' => row[:min_ms]&.round(3),
                  'max_ms' => row[:max_ms]&.round(3),
                  'allocations' => row[:allocations].to_i
                }.compact
              end
            end

            def runtime_metadata
              {
                'ruby_version' => RUBY_VERSION,
                'ruby_platform' => RUBY_PLATFORM,
                'sketchup_version' => (Sketchup.version if defined?(Sketchup) && Sketchup.respond_to?(:version))
              }.compact
            end

            def gc_snapshot
              GC.stat.each_with_object({}) do |(key, value), result|
                result[key.to_s] = value if value.is_a?(Numeric)
              end
            rescue StandardError
              {}
            end

            def numeric_delta(before, after)
              after.each_with_object({}) do |(key, value), result|
                next unless before[key].is_a?(Numeric) && value.is_a?(Numeric)

                result[key] = value - before[key]
              end
            end

            def allocated_objects
              GC.stat(:total_allocated_objects).to_i
            rescue StandardError
              0
            end

            def monotonic_now
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end

            def sorted_hash(hash)
              hash.keys.sort.each_with_object({}) { |key, result| result[key.to_s] = hash[key] }
            end
          end

          class << self
            attr_reader :last_report_path, :last_snapshot

            def current
              Thread.current[THREAD_RECORDER_KEY]
            end

            def current=(recorder)
              Thread.current[THREAD_RECORDER_KEY] = recorder
            end

            def write_report(runner, recorder)
              snapshot = recorder.snapshot
              path = File.join(
                runner.instance_variable_get(:@work_dir),
                "#{runner.instance_variable_get(:@report_name)}_recheck_benchmark.json"
              )
              File.write(path, JSON.pretty_generate(snapshot), encoding: 'UTF-8')
              @last_report_path = path
              @last_snapshot = snapshot
              log_summary(snapshot, path)
              path
            rescue StandardError => e
              log("benchmark report write failed: #{e.class}: #{e.message}")
              nil
            end

            def log_summary(snapshot, path)
              log("recheck benchmark: #{snapshot['elapsed_ms']} ms, pairs=#{snapshot.dig('counters', 'unique_pair_cache_miss').to_i}, errors=#{snapshot.dig('counters', 'recheck_error_calls').to_i}")
              Array(snapshot['hotspots']).first(8).each do |row|
                log(format('  %-42s %10.3f ms  count=%d', row['stage'], row['total_ms'], row['count']))
              end
              log("recheck benchmark report: #{path}")
            end

            def log(message)
              text = "[IndoorGML][RecheckBenchmark] #{message}"
              if defined?(IndoorCore::Logger) && IndoorCore::Logger.respond_to?(:puts)
                IndoorCore::Logger.puts(text)
              else
                puts(text)
              end
            rescue StandardError
              nil
            end
          end

          module RunnerPatch
            private

            def recheck_overlap_errors!(raw_report, progress: nil, progress_step: nil)
              recorder = Recorder.new(
                'gml_path' => instance_variable_get(:@gml_path),
                'report_name' => instance_variable_get(:@report_name),
                'work_dir' => instance_variable_get(:@work_dir)
              )
              Val3dityRecheckBenchmarkProbe.current = recorder
              recorder.measure('runner.recheck_overlap_errors') do
                super
              end
            ensure
              Val3dityRecheckBenchmarkProbe.write_report(self, recorder) if recorder
              Val3dityRecheckBenchmarkProbe.current = nil
            end

            def recheck_cell_pair(code, cell_id1, cell_id2)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.increment('recheck_error_calls')
              recorder.increment("recheck_code_#{code}")
              recorder.with_pair(cell_id1, cell_id2) do
                recorder.measure('runner.recheck_cell_pair') { super }
              end
            end

            def emit_overlap_recheck_progress(*args, **kwargs)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.increment('progress_update_calls')
              recorder.measure('runner.emit_progress') { super }
            end
          end

          module PolicyPatch
            def count_recheckable_errors(raw_report)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.measure('policy.count_recheckable_errors') { super }
            end

            def apply!(*args, **kwargs, &block)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.measure('policy.apply') { super }
            end

            private

            def recheck_error(*args, &block)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.measure('policy.recheck_error_parse') { super }
            end

            def refresh_validity!(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.measure('policy.refresh_validity') { super }
            end
          end

          module RecheckerPatch
            def pair_analysis(cell_id1, cell_id2)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              key = [cell_id1.to_s, cell_id2.to_s].sort.join('|')
              cache = instance_variable_get(:@pair_analysis) || {}
              if cache.key?(key)
                recorder.increment('pair_analysis_cache_hit')
              else
                recorder.increment('unique_pair_cache_miss')
              end
              recorder.measure('rechecker.pair_analysis') { super }
            end

            private

            def analyze_pair(cell_id1, cell_id2)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.with_pair(cell_id1, cell_id2) do
                result = recorder.measure('rechecker.analyze_pair') { super }
                recorder.record_pair_result(result)
                result
              end
            end

            def model_cell_geometry(report_cell_id)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              cache = instance_variable_get(:@cell_geometry) || {}
              recorder.increment(cache.key?(report_cell_id) ? 'cell_geometry_cache_hit' : 'cell_geometry_cache_miss')
              result = recorder.measure('rechecker.model_cell_geometry') { super }
              recorder.observe("cell_#{report_cell_id}_face_count", Array(result[:faces]).length) if result.is_a?(Hash) && result[:status] == :ok
              result
            end

            def entity_faces(entity)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              result = recorder.measure('rechecker.entity_faces') { super }
              recorder.increment('faces_extracted', Array(result).length)
              result
            end

            def shared_face_candidates(faces1, faces2)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.increment('face_pair_comparisons', Array(faces1).length * Array(faces2).length)
              recorder.observe('faces1_count', Array(faces1).length)
              recorder.observe('faces2_count', Array(faces2).length)
              result = recorder.measure('rechecker.shared_face_candidates') { super }
              recorder.increment('adjacency_candidates', Array(result).length)
              result
            end

            def coplanar_overlap_polygons(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.increment('coplanar_overlap_calls')
              recorder.measure('rechecker.coplanar_overlap_polygons') { super }
            end

            def triangle_set_overlap(triangles1, triangles2, *args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.increment('triangle_set_overlap_calls')
              recorder.increment('triangle_pair_comparisons', Array(triangles1).length * Array(triangles2).length)
              recorder.measure('rechecker.triangle_set_overlap') { super }
            end

            def model_solid_intersection(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.increment('boolean_pair_calls')
              result = recorder.measure('rechecker.model_solid_intersection') { super }
              recorder.increment("boolean_status_#{result[:status]}") if result.is_a?(Hash)
              result
            end

            def build_boolean_copy(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.increment('boolean_copy_calls')
              recorder.measure('rechecker.build_boolean_copy') { super }
            end

            def valid_manifold_group?(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.increment('manifold_check_calls')
              recorder.measure('rechecker.valid_manifold_group') { super }
            end

            def solid_group_volume(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.increment('volume_query_calls')
              recorder.measure('rechecker.solid_group_volume') { super }
            end

            def non_solid_intersection_result(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.measure('rechecker.non_solid_intersection_result') { super }
            end

            def resolve_non_solid_intersection(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.measure('rechecker.resolve_non_solid_intersection') { super }
            end

            def cache_intersection_overlay_geometry(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.increment('overlay_cache_calls')
              recorder.measure('rechecker.cache_intersection_overlay_geometry') { super }
            end

            def intersection_overlay_geometry(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.measure('rechecker.intersection_overlay_geometry') { super }
            end

            def face_components(*args)
              recorder = Val3dityRecheckBenchmarkProbe.current
              return super unless recorder

              recorder.measure('rechecker.face_components') { super }
            end
          end
        end

        unless Val3dityRunner.ancestors.include?(Val3dityRecheckBenchmarkProbe::RunnerPatch)
          Val3dityRunner.prepend(Val3dityRecheckBenchmarkProbe::RunnerPatch)
        end
        unless Val3dityOverlapRecheckPolicy.ancestors.include?(Val3dityRecheckBenchmarkProbe::PolicyPatch)
          Val3dityOverlapRecheckPolicy.prepend(Val3dityRecheckBenchmarkProbe::PolicyPatch)
        end
        unless Val3dityOverlapGeometryRechecker.ancestors.include?(Val3dityRecheckBenchmarkProbe::RecheckerPatch)
          Val3dityOverlapGeometryRechecker.prepend(Val3dityRecheckBenchmarkProbe::RecheckerPatch)
        end

        Val3dityRecheckBenchmarkProbe.log('probe enabled; run the normal Validation Check once')
      end
    end
  end
end
