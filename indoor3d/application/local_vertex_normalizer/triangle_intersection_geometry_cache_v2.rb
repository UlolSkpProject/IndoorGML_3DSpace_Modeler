# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Reuses immutable geometry facts only while one exact triangle-intersection
      # collection is running. The exact intersection predicate itself is unchanged;
      # repeated calls to integer_triangle_normal for the same triangle object simply
      # reuse the first exact integer result.
      module LocalVertexNormalizerTriangleIntersectionGeometryCacheV2
        private

        def normalize_entity(entity)
          previous_stats = @local_vertex_normalizer_triangle_geometry_cache_stats_v2
          previous_context = @local_vertex_normalizer_triangle_geometry_cache_context_v2
          @local_vertex_normalizer_triangle_geometry_cache_stats_v2 = {
            collect_calls: 0,
            contexts: 0,
            normal_calls: 0,
            normal_hits: 0,
            normal_misses: 0,
            max_cached_triangles: 0
          }
          @local_vertex_normalizer_triangle_geometry_cache_context_v2 = nil

          super
        ensure
          stats = @local_vertex_normalizer_triangle_geometry_cache_stats_v2
          emit_triangle_intersection_geometry_cache_v2(stats) if stats
          @local_vertex_normalizer_triangle_geometry_cache_stats_v2 = previous_stats
          @local_vertex_normalizer_triangle_geometry_cache_context_v2 = previous_context
        end

        def collect_triangle_intersection_failures(triangles, partition_ids: nil)
          stats = @local_vertex_normalizer_triangle_geometry_cache_stats_v2
          return super unless stats

          stats[:collect_calls] += 1
          previous_context = @local_vertex_normalizer_triangle_geometry_cache_context_v2
          root_context = previous_context.nil?

          if root_context
            @local_vertex_normalizer_triangle_geometry_cache_context_v2 = {
              normals: {}
            }
            stats[:contexts] += 1
          end

          super
        ensure
          if stats && root_context
            context = @local_vertex_normalizer_triangle_geometry_cache_context_v2
            cached = context ? context[:normals].length : 0
            stats[:max_cached_triangles] = [stats[:max_cached_triangles], cached].max
            @local_vertex_normalizer_triangle_geometry_cache_context_v2 = previous_context
          end
        end

        def integer_triangle_normal(triangle)
          context = @local_vertex_normalizer_triangle_geometry_cache_context_v2
          stats = @local_vertex_normalizer_triangle_geometry_cache_stats_v2
          return super unless context && stats

          stats[:normal_calls] += 1
          key = triangle.object_id
          cached = context[:normals][key]
          if cached && cached[0].equal?(triangle)
            stats[:normal_hits] += 1
            return cached[1]
          end

          normal = super
          context[:normals][key] = [triangle, normal]
          stats[:normal_misses] += 1
          normal
        end

        def emit_triangle_intersection_geometry_cache_v2(stats)
          profile = @local_vertex_normalizer_debug_profile
          return unless profile && profile[:verbose]
          return unless respond_to?(:debug_profile_log, true)

          calls = stats[:normal_calls]
          hits = stats[:normal_hits]
          hit_rate = calls.positive? ? (100.0 * hits / calls) : 0.0
          debug_profile_log(
            format(
              'WORK triangle_intersection_geometry_cache collect_calls=%d contexts=%d normal_calls=%d hits=%d misses=%d hit_rate=%.2f%% max_cached_triangles=%d',
              stats[:collect_calls],
              stats[:contexts],
              calls,
              hits,
              stats[:normal_misses],
              hit_rate,
              stats[:max_cached_triangles]
            )
          )
        rescue StandardError
          nil
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerTriangleIntersectionGeometryCacheV2 unless
          ancestors.include?(LocalVertexNormalizerTriangleIntersectionGeometryCacheV2)
      end
    end
  end
end
