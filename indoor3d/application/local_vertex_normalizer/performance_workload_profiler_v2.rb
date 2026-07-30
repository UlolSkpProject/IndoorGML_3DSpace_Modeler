# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Adds lightweight workload counters to the existing optional LVN profiler.
      # The counters are active only while debug/report profiling is enabled and
      # never alter geometry decisions or cached values used by production code.
      module LocalVertexNormalizerPerformanceWorkloadProfilerV2
        private

        def normalize_entity(entity)
          profile = @local_vertex_normalizer_debug_profile
          return super unless profile

          previous_exact_context = @local_vertex_normalizer_exact_polygon_workload_v2
          @local_vertex_normalizer_exact_polygon_workload_v2 = {
            calls: 0,
            total_seconds: 0.0,
            failures: 0,
            by_role: {},
            signatures: {},
            next_signature_id: 1,
            wrapper_calls: 0,
            record_errors: 0
          }

          super
        ensure
          if profile
            emit_exact_polygon_workload_summary_v2(
              profile,
              @local_vertex_normalizer_exact_polygon_workload_v2
            )
            @local_vertex_normalizer_exact_polygon_workload_v2 = previous_exact_context
          end
        end

        def source_boundary_triangle_records(face, source_face_key)
          profile = @local_vertex_normalizer_debug_profile
          return super unless profile

          previous_face_key = @local_vertex_normalizer_exact_polygon_face_key_v2
          @local_vertex_normalizer_exact_polygon_face_key_v2 = source_face_key
          super
        ensure
          if profile
            @local_vertex_normalizer_exact_polygon_face_key_v2 = previous_face_key
          end
        end

        def triangulate_exact_polygon_with_holes(outer, holes, drop_axis)
          profile = @local_vertex_normalizer_debug_profile
          context = @local_vertex_normalizer_exact_polygon_workload_v2
          return super unless profile && context

          context[:wrapper_calls] += 1
          role = @local_vertex_normalizer_debug_snapshot_role || :unscoped
          face_key = @local_vertex_normalizer_exact_polygon_face_key_v2
          outer_vertex_count = outer.respond_to?(:length) ? outer.length : 0
          hole_count = holes.respond_to?(:length) ? holes.length : 0
          hole_vertex_count = if holes.respond_to?(:sum)
                                holes.sum { |hole| hole.respond_to?(:length) ? hole.length : 0 }
                              else
                                0
                              end
          boundary_vertex_count = outer_vertex_count + hole_vertex_count
          signature = begin
            exact_polygon_workload_signature_v2(outer, holes, drop_axis)
          rescue StandardError
            nil
          end
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          succeeded = false
          output_triangle_count = nil

          result = super
          succeeded = true
          output_triangle_count = result.length if result.respond_to?(:length)
          result
        ensure
          if profile && context && started_at
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            begin
              record_exact_polygon_workload_v2(
                context,
                role: role,
                face_key: face_key,
                signature: signature,
                outer_vertex_count: outer_vertex_count,
                hole_count: hole_count,
                hole_vertex_count: hole_vertex_count,
                boundary_vertex_count: boundary_vertex_count,
                output_triangle_count: output_triangle_count,
                elapsed_seconds: elapsed,
                succeeded: succeeded
              )
            rescue StandardError => error
              context[:record_errors] += 1
              puts "[LVN DEBUG] WORK exact_polygon_record_error #{error.class}: #{error.message}" if
                profile[:verbose]
            end
          end
        end

        def conforming_triangle_snapshot(
          source_triangles,
          coordinate_space: :grid,
          duplicate_diagnostics: nil
        )
          profile = @local_vertex_normalizer_debug_profile
          return super unless profile

          previous_context = @local_vertex_normalizer_conforming_workload_v2
          context = {
            stage: "conforming_#{coordinate_space}".to_sym,
            coordinate_space: coordinate_space,
            input_triangle_count: source_triangles.length,
            candidate_pool_size: nil,
            unique_edge_keys: {},
            edge_calls: 0,
            edge_cache_hits: 0,
            edge_cache_misses: 0,
            uncached_edge_calls: 0,
            candidate_scan_calls: 0,
            candidate_point_tests: 0,
            split_point_count: 0
          }
          @local_vertex_normalizer_conforming_workload_v2 = context

          result = super
          context[:output_triangle_count] = result.length if result.respond_to?(:length)
          result
        ensure
          if context
            record_conforming_workload_v2(context)
            @local_vertex_normalizer_conforming_workload_v2 = previous_context
          end
        end

        def conforming_edge_interior_points(
          start_point,
          end_point,
          candidates,
          coordinate_space:,
          edge_split_cache:
        )
          context = @local_vertex_normalizer_conforming_workload_v2
          if context
            start_key = triangle_point_key(start_point, coordinate_space)
            end_key = triangle_point_key(end_point, coordinate_space)
            forward = (start_key <=> end_key) <= 0
            edge_key = forward ? [start_key, end_key] : [end_key, start_key]

            context[:edge_calls] += 1
            context[:unique_edge_keys][edge_key] = true
            if edge_split_cache
              if edge_split_cache.key?(edge_key)
                context[:edge_cache_hits] += 1
              else
                context[:edge_cache_misses] += 1
              end
            else
              context[:uncached_edge_calls] += 1
            end
          end

          super
        end

        def conforming_edge_interior_points_in_direction(
          start_point,
          end_point,
          candidates,
          coordinate_space
        )
          context = @local_vertex_normalizer_conforming_workload_v2
          if context
            context[:candidate_pool_size] ||= candidates.length
            context[:candidate_scan_calls] += 1
            context[:candidate_point_tests] += candidates.length
          end

          result = super
          context[:split_point_count] += result.length if context && result.respond_to?(:length)
          result
        end

        def exact_polygon_workload_signature_v2(outer, holes, drop_axis)
          outer_signature = exact_polygon_loop_edge_signature_v2(outer)
          hole_signatures = Array(holes).map do |hole|
            exact_polygon_loop_edge_signature_v2(hole)
          end.sort
          "axis=#{drop_axis};outer=#{outer_signature};holes=#{hole_signatures.join('||')}"
        end

        def exact_polygon_loop_edge_signature_v2(loop)
          points = Array(loop).map { |point| exact_polygon_point_signature_v2(point) }
          return points.join('>') if points.length < 2

          points.each_index.map do |index|
            first = points[index]
            second = points[(index + 1) % points.length]
            first <= second ? "#{first}>#{second}" : "#{second}>#{first}"
          end.sort.join('|')
        end

        def exact_polygon_point_signature_v2(point)
          values = if point.respond_to?(:to_a)
                     point.to_a
                   elsif point.is_a?(Array)
                     point
                   else
                     [point]
                   end
          Array(values).map(&:to_s).join(',')
        end

        def record_exact_polygon_workload_v2(
          workload,
          role:,
          face_key:,
          signature:,
          outer_vertex_count:,
          hole_count:,
          hole_vertex_count:,
          boundary_vertex_count:,
          output_triangle_count:,
          elapsed_seconds:,
          succeeded:
        )
          workload[:calls] += 1
          workload[:total_seconds] += elapsed_seconds
          workload[:failures] += 1 unless succeeded

          role_stats = workload[:by_role][role] ||= {
            calls: 0,
            total_seconds: 0.0,
            failures: 0,
            max_seconds: 0.0,
            max_boundary_vertex_count: 0,
            max_outer_vertex_count: 0,
            total_boundary_vertex_count: 0,
            total_hole_count: 0,
            signatures: {}
          }
          role_stats[:calls] += 1
          role_stats[:total_seconds] += elapsed_seconds
          role_stats[:failures] += 1 unless succeeded
          role_stats[:max_seconds] = [role_stats[:max_seconds], elapsed_seconds].max
          role_stats[:max_boundary_vertex_count] = [
            role_stats[:max_boundary_vertex_count],
            boundary_vertex_count
          ].max
          role_stats[:max_outer_vertex_count] = [
            role_stats[:max_outer_vertex_count],
            outer_vertex_count
          ].max
          role_stats[:total_boundary_vertex_count] += boundary_vertex_count
          role_stats[:total_hole_count] += hole_count

          return unless signature

          signature_stats = workload[:signatures][signature]
          unless signature_stats
            signature_stats = {
              id: workload[:next_signature_id],
              calls: 0,
              total_seconds: 0.0,
              max_seconds: 0.0,
              failures: 0,
              roles: {},
              face_keys: {},
              outer_vertex_count: outer_vertex_count,
              hole_count: hole_count,
              hole_vertex_count: hole_vertex_count,
              boundary_vertex_count: boundary_vertex_count,
              max_output_triangle_count: 0
            }
            workload[:next_signature_id] += 1
            workload[:signatures][signature] = signature_stats
          end
          signature_stats[:calls] += 1
          signature_stats[:total_seconds] += elapsed_seconds
          signature_stats[:max_seconds] = [signature_stats[:max_seconds], elapsed_seconds].max
          signature_stats[:failures] += 1 unless succeeded
          signature_stats[:roles][role] = signature_stats[:roles].fetch(role, 0) + 1
          signature_stats[:face_keys][face_key] = true if face_key
          signature_stats[:max_output_triangle_count] = [
            signature_stats[:max_output_triangle_count],
            output_triangle_count.to_i
          ].max
          role_stats[:signatures][signature] = role_stats[:signatures].fetch(signature, 0) + 1
        end

        def emit_exact_polygon_workload_summary_v2(profile, workload)
          return unless profile[:verbose]
          return unless respond_to?(:debug_profile_log, true)

          unless workload
            debug_profile_log('WORK exact_polygon_summary state=no_context')
            return
          end

          debug_profile_log(
            "WORK exact_polygon_probe wrapper_calls=#{workload[:wrapper_calls]} " \
            "recorded_calls=#{workload[:calls]} record_errors=#{workload[:record_errors]}"
          )
          return unless workload[:calls].positive?

          signatures = workload[:signatures].values
          repeated = signatures.select { |stats| stats[:calls] > 1 }
          repeated_calls = repeated.sum { |stats| stats[:calls] - 1 }
          repeated_seconds = repeated.sum { |stats| stats[:total_seconds] }
          debug_profile_log(
            format(
              'WORK exact_polygon_summary calls=%d total=%.6fs unique_signatures=%d repeat_calls=%d repeated_signature_time=%.6fs failures=%d',
              workload[:calls],
              workload[:total_seconds],
              signatures.length,
              repeated_calls,
              repeated_seconds,
              workload[:failures]
            )
          )

          workload[:by_role].sort_by { |_role, stats| -stats[:total_seconds] }.each do |role, stats|
            unique_count = stats[:signatures].length
            repeat_count = stats[:signatures].values.sum { |count| [count - 1, 0].max }
            debug_profile_log(
              format(
                'WORK exact_polygon_role %s calls=%d total=%.6fs unique=%d repeats=%d max=%.6fs max_boundary=%d max_outer=%d holes=%d',
                role,
                stats[:calls],
                stats[:total_seconds],
                unique_count,
                repeat_count,
                stats[:max_seconds],
                stats[:max_boundary_vertex_count],
                stats[:max_outer_vertex_count],
                stats[:total_hole_count]
              )
            )
          end

          signatures.sort_by { |stats| -stats[:total_seconds] }.first(12).each do |stats|
            roles = stats[:roles].sort_by { |role, _count| role.to_s }.map do |role, count|
              "#{role}:#{count}"
            end.join(',')
            debug_profile_log(
              format(
                'WORK exact_polygon_hot sig=%d calls=%d total=%.6fs max=%.6fs boundary=%d outer=%d holes=%d out_triangles=%d roles=%s',
                stats[:id],
                stats[:calls],
                stats[:total_seconds],
                stats[:max_seconds],
                stats[:boundary_vertex_count],
                stats[:outer_vertex_count],
                stats[:hole_count],
                stats[:max_output_triangle_count],
                roles
              )
            )
          end
        rescue StandardError => error
          puts "[LVN DEBUG] WORK exact_polygon_summary_error #{error.class}: #{error.message}"
        end

        def record_conforming_workload_v2(context)
          profile = @local_vertex_normalizer_debug_profile
          return unless profile

          sample = {
            stage: context[:stage],
            coordinate_space: context[:coordinate_space],
            input_triangle_count: context[:input_triangle_count],
            output_triangle_count: context[:output_triangle_count],
            unique_vertex_count: context[:candidate_pool_size],
            unique_edge_count: context[:unique_edge_keys].length,
            edge_calls: context[:edge_calls],
            edge_cache_hits: context[:edge_cache_hits],
            edge_cache_misses: context[:edge_cache_misses],
            uncached_edge_calls: context[:uncached_edge_calls],
            candidate_scan_calls: context[:candidate_scan_calls],
            candidate_point_tests: context[:candidate_point_tests],
            split_point_count: context[:split_point_count]
          }
          profile[:performance_workloads] ||= []
          profile[:performance_workloads] << sample

          aggregate = (profile[:performance_counters] ||= {})[context[:stage]] ||= {
            calls: 0,
            input_triangle_count: 0,
            output_triangle_count: 0,
            max_unique_vertex_count: 0,
            unique_edge_count: 0,
            edge_calls: 0,
            edge_cache_hits: 0,
            edge_cache_misses: 0,
            uncached_edge_calls: 0,
            candidate_scan_calls: 0,
            candidate_point_tests: 0,
            split_point_count: 0
          }
          aggregate[:calls] += 1
          aggregate[:input_triangle_count] += sample[:input_triangle_count].to_i
          aggregate[:output_triangle_count] += sample[:output_triangle_count].to_i
          aggregate[:max_unique_vertex_count] = [
            aggregate[:max_unique_vertex_count],
            sample[:unique_vertex_count].to_i
          ].max
          aggregate[:unique_edge_count] += sample[:unique_edge_count]
          aggregate[:edge_calls] += sample[:edge_calls]
          aggregate[:edge_cache_hits] += sample[:edge_cache_hits]
          aggregate[:edge_cache_misses] += sample[:edge_cache_misses]
          aggregate[:uncached_edge_calls] += sample[:uncached_edge_calls]
          aggregate[:candidate_scan_calls] += sample[:candidate_scan_calls]
          aggregate[:candidate_point_tests] += sample[:candidate_point_tests]
          aggregate[:split_point_count] += sample[:split_point_count]

          return unless profile[:verbose] && respond_to?(:debug_profile_log, true)

          debug_profile_log(
            "WORK #{context[:stage]} " \
            "triangles=#{sample[:input_triangle_count]}->#{sample[:output_triangle_count]} " \
            "vertices=#{sample[:unique_vertex_count]} edges=#{sample[:unique_edge_count]} " \
            "cache=#{sample[:edge_cache_hits]}/#{sample[:edge_cache_misses]} " \
            "candidate_tests=#{sample[:candidate_point_tests]} " \
            "split_points=#{sample[:split_point_count]}"
          )
        rescue StandardError
          # Profiling must never change normalization behavior.
          nil
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerPerformanceWorkloadProfilerV2 unless
          ancestors.include?(LocalVertexNormalizerPerformanceWorkloadProfilerV2)
      end
    end
  end
end
