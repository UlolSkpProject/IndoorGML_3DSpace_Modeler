# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Reuses only successful exact triangle-intersection validation results for
      # an identical canonical triangle set within one normalize_entity call.
      # Invalid results are never cached, so every failing mesh still reaches the
      # unchanged exact predicate and produces its original invalid pair indices.
      module LocalVertexNormalizerTriangleIntersectionCleanCache
        TRIANGLE_INTERSECTION_CLEAN_CACHE_MIN_TRIANGLES = 8
        TRIANGLE_INTERSECTION_CLEAN_CACHE_MAX_ENTRIES = 32

        private

        def normalize_entity(entity)
          previous_cache = @local_vertex_normalizer_triangle_intersection_clean_cache
          previous_order = @local_vertex_normalizer_triangle_intersection_clean_cache_order
          previous_stats = @local_vertex_normalizer_triangle_intersection_clean_cache_stats
          @local_vertex_normalizer_triangle_intersection_clean_cache = {}
          @local_vertex_normalizer_triangle_intersection_clean_cache_order = []
          @local_vertex_normalizer_triangle_intersection_clean_cache_stats = {
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
          stats = @local_vertex_normalizer_triangle_intersection_clean_cache_stats
          if stats && @local_vertex_normalizer_diagnostic_profile &&
             respond_to?(:diagnostic_profile_log, true)
            diagnostic_profile_log(
              "WORK triangle_intersection_clean_cache hits=#{stats[:hits]} " \
              "misses=#{stats[:misses]} stores=#{stats[:stores]} " \
              "entries=#{@local_vertex_normalizer_triangle_intersection_clean_cache&.length.to_i} " \
              "evictions=#{stats[:evictions]} " \
              "saved_tested_pairs=#{stats[:saved_tested_pairs]} " \
              "bypassed_small=#{stats[:bypassed_small]} " \
              "bypassed_partitioned=#{stats[:bypassed_partitioned]}"
            )
          end
          @local_vertex_normalizer_triangle_intersection_clean_cache = previous_cache
          @local_vertex_normalizer_triangle_intersection_clean_cache_order = previous_order
          @local_vertex_normalizer_triangle_intersection_clean_cache_stats = previous_stats
        end

        def collect_triangle_intersection_failures(triangles, partition_ids: nil)
          cache = @local_vertex_normalizer_triangle_intersection_clean_cache
          stats = @local_vertex_normalizer_triangle_intersection_clean_cache_stats
          return super unless cache && stats

          if partition_ids
            stats[:bypassed_partitioned] += 1
            return super
          end
          if triangles.length < TRIANGLE_INTERSECTION_CLEAN_CACHE_MIN_TRIANGLES
            stats[:bypassed_small] += 1
            return super
          end

          key = triangle_intersection_clean_cache_key(triangles)
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

          triangle_intersection_clean_cache_store(
            cache,
            key,
            tested_pairs: result[:tested_pairs].to_i
          )
          stats[:stores] += 1
          result
        end

        def triangle_intersection_clean_cache_key(triangles)
          Array(triangles).map do |triangle|
            canonical_triangle_key(triangle).map do |point|
              Array(point).map { |coordinate| coordinate }.freeze
            end.freeze
          end.sort.freeze
        end

        def triangle_intersection_clean_cache_store(cache, key, tested_pairs:)
          order = @local_vertex_normalizer_triangle_intersection_clean_cache_order
          stats = @local_vertex_normalizer_triangle_intersection_clean_cache_stats

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
        prepend LocalVertexNormalizerTriangleIntersectionCleanCache unless
          ancestors.include?(LocalVertexNormalizerTriangleIntersectionCleanCache)
      end
    end
  end
end
