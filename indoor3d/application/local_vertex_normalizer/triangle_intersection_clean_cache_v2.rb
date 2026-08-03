# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Reuses only successful exact triangle-intersection validation results for
      # an identical canonical triangle set within one normalize_entity call.
      # Invalid results are never cached, so every failing mesh still reaches the
      # unchanged exact predicate and produces its original invalid pair indices.
      module LocalVertexNormalizerTriangleIntersectionCleanCacheV2
        TRIANGLE_INTERSECTION_CLEAN_CACHE_MIN_TRIANGLES = 8
        TRIANGLE_INTERSECTION_CLEAN_CACHE_MAX_ENTRIES = 32

        private

        def normalize_entity(entity)
          previous_cache = @local_vertex_normalizer_triangle_intersection_clean_cache_v2
          previous_order = @local_vertex_normalizer_triangle_intersection_clean_cache_order_v2
          previous_stats = @local_vertex_normalizer_triangle_intersection_clean_cache_stats_v2
          @local_vertex_normalizer_triangle_intersection_clean_cache_v2 = {}
          @local_vertex_normalizer_triangle_intersection_clean_cache_order_v2 = []
          @local_vertex_normalizer_triangle_intersection_clean_cache_stats_v2 = {
            hits: 0,
            misses: 0,
            stores: 0,
            evictions: 0,
            bypassed_small: 0,
            bypassed_partitioned: 0,
            saved_tested_pairs: 0
          }

          super
        ensure
          stats = @local_vertex_normalizer_triangle_intersection_clean_cache_stats_v2
          if stats && @local_vertex_normalizer_debug_profile &&
             respond_to?(:debug_profile_log, true)
            debug_profile_log(
              "WORK triangle_intersection_clean_cache hits=#{stats[:hits]} " \
              "misses=#{stats[:misses]} stores=#{stats[:stores]} " \
              "entries=#{@local_vertex_normalizer_triangle_intersection_clean_cache_v2&.length.to_i} " \
              "evictions=#{stats[:evictions]} " \
              "saved_tested_pairs=#{stats[:saved_tested_pairs]} " \
              "bypassed_small=#{stats[:bypassed_small]} " \
              "bypassed_partitioned=#{stats[:bypassed_partitioned]}"
            )
          end
          @local_vertex_normalizer_triangle_intersection_clean_cache_v2 = previous_cache
          @local_vertex_normalizer_triangle_intersection_clean_cache_order_v2 = previous_order
          @local_vertex_normalizer_triangle_intersection_clean_cache_stats_v2 = previous_stats
        end

        def collect_triangle_intersection_failures(triangles, partition_ids: nil)
          cache = @local_vertex_normalizer_triangle_intersection_clean_cache_v2
          stats = @local_vertex_normalizer_triangle_intersection_clean_cache_stats_v2
          return super unless cache && stats

          if partition_ids
            stats[:bypassed_partitioned] += 1
            return super
          end
          if triangles.length < TRIANGLE_INTERSECTION_CLEAN_CACHE_MIN_TRIANGLES
            stats[:bypassed_small] += 1
            return super
          end

          key = triangle_intersection_clean_cache_key_v2(triangles)
          cached = cache[key]
          if cached
            stats[:hits] += 1
            stats[:saved_tested_pairs] += cached[:tested_pairs]
            return {
              tested_pairs: cached[:tested_pairs],
              pairs: []
            }
          end

          stats[:misses] += 1
          result = super
          return result unless Array(result[:pairs]).empty?

          triangle_intersection_clean_cache_store_v2(
            cache,
            key,
            tested_pairs: result[:tested_pairs].to_i
          )
          stats[:stores] += 1
          result
        end

        def triangle_intersection_clean_cache_key_v2(triangles)
          Array(triangles).map do |triangle|
            canonical_triangle_key(triangle).map do |point|
              Array(point).map { |coordinate| coordinate }.freeze
            end.freeze
          end.sort.freeze
        end

        def triangle_intersection_clean_cache_store_v2(cache, key, tested_pairs:)
          order = @local_vertex_normalizer_triangle_intersection_clean_cache_order_v2
          stats = @local_vertex_normalizer_triangle_intersection_clean_cache_stats_v2

          if cache.length >= TRIANGLE_INTERSECTION_CLEAN_CACHE_MAX_ENTRIES
            oldest = order.shift
            if oldest && cache.delete(oldest)
              stats[:evictions] += 1
            end
          end

          cache[key] = { tested_pairs: tested_pairs }.freeze
          order << key
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerTriangleIntersectionCleanCacheV2 unless
          ancestors.include?(LocalVertexNormalizerTriangleIntersectionCleanCacheV2)
      end
    end
  end
end
