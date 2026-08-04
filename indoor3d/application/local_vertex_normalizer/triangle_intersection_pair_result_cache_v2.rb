# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Reuses the exact Boolean result for an identical unordered triangle pair
      # only while normalized mesh hard gates run within one normalize_entity call.
      #
      # The underlying exact predicate is unchanged. Both allowed and rejected
      # results are cached because they are deterministic geometry facts; raised
      # exceptions are never cached. Source-boundary and other intersection scopes
      # remain on the original path.
      module LocalVertexNormalizerTriangleIntersectionPairResultCacheV2
        TRIANGLE_INTERSECTION_PAIR_RESULT_CACHE_MAX_ENTRIES = 131_072
        TRIANGLE_INTERSECTION_PAIR_RESULT_CACHE_ID_SHIFT = 32
        TRIANGLE_INTERSECTION_PAIR_RESULT_CACHE_ALLOWED = 1
        TRIANGLE_INTERSECTION_PAIR_RESULT_CACHE_REJECTED = 2

        private

        def normalize_entity(entity)
          previous_cache = @local_vertex_normalizer_triangle_pair_result_cache_v2
          previous_triangle_ids = @local_vertex_normalizer_triangle_pair_triangle_ids_v2
          previous_object_ids = @local_vertex_normalizer_triangle_pair_object_ids_v2
          previous_next_id = @local_vertex_normalizer_triangle_pair_next_id_v2
          previous_active = @local_vertex_normalizer_triangle_pair_cache_active_v2
          previous_stats = @local_vertex_normalizer_triangle_pair_cache_stats_v2

          @local_vertex_normalizer_triangle_pair_result_cache_v2 = {}
          @local_vertex_normalizer_triangle_pair_triangle_ids_v2 = {}
          @local_vertex_normalizer_triangle_pair_object_ids_v2 = {}
          @local_vertex_normalizer_triangle_pair_next_id_v2 = 0
          @local_vertex_normalizer_triangle_pair_cache_active_v2 = false
          @local_vertex_normalizer_triangle_pair_cache_stats_v2 = {
            calls: 0,
            hits: 0,
            misses: 0,
            stores: 0,
            allowed_hits: 0,
            rejected_hits: 0,
            bypassed_inactive: 0,
            bypassed_full: 0,
            triangle_id_hits: 0,
            triangle_id_misses: 0
          }

          super
        ensure
          publish_triangle_intersection_pair_result_cache_v2
          @local_vertex_normalizer_triangle_pair_result_cache_v2 = previous_cache
          @local_vertex_normalizer_triangle_pair_triangle_ids_v2 = previous_triangle_ids
          @local_vertex_normalizer_triangle_pair_object_ids_v2 = previous_object_ids
          @local_vertex_normalizer_triangle_pair_next_id_v2 = previous_next_id
          @local_vertex_normalizer_triangle_pair_cache_active_v2 = previous_active
          @local_vertex_normalizer_triangle_pair_cache_stats_v2 = previous_stats
        end

        def validate_normalized_triangle_mesh!(triangle_records)
          previous_active = @local_vertex_normalizer_triangle_pair_cache_active_v2
          @local_vertex_normalizer_triangle_pair_cache_active_v2 = true
          super
        ensure
          @local_vertex_normalizer_triangle_pair_cache_active_v2 = previous_active
        end

        def exact_triangle_intersection_allowed?(triangle_a, triangle_b)
          cache = @local_vertex_normalizer_triangle_pair_result_cache_v2
          stats = @local_vertex_normalizer_triangle_pair_cache_stats_v2
          unless cache && stats && @local_vertex_normalizer_triangle_pair_cache_active_v2
            stats[:bypassed_inactive] += 1 if stats
            return super
          end

          stats[:calls] += 1
          triangle_a_id = triangle_intersection_pair_cache_triangle_id_v2(triangle_a)
          triangle_b_id = triangle_intersection_pair_cache_triangle_id_v2(triangle_b)
          if triangle_a_id <= triangle_b_id
            low_id = triangle_a_id
            high_id = triangle_b_id
          else
            low_id = triangle_b_id
            high_id = triangle_a_id
          end
          pair_key = (low_id << TRIANGLE_INTERSECTION_PAIR_RESULT_CACHE_ID_SHIFT) | high_id
          cached = cache[pair_key]
          if cached
            stats[:hits] += 1
            if cached == TRIANGLE_INTERSECTION_PAIR_RESULT_CACHE_ALLOWED
              stats[:allowed_hits] += 1
              return true
            end

            stats[:rejected_hits] += 1
            return false
          end

          stats[:misses] += 1
          result = super
          if cache.length < TRIANGLE_INTERSECTION_PAIR_RESULT_CACHE_MAX_ENTRIES
            cache[pair_key] = result ?
              TRIANGLE_INTERSECTION_PAIR_RESULT_CACHE_ALLOWED :
              TRIANGLE_INTERSECTION_PAIR_RESULT_CACHE_REJECTED
            stats[:stores] += 1
          else
            stats[:bypassed_full] += 1
          end
          result
        end

        def triangle_intersection_pair_cache_triangle_id_v2(triangle)
          object_cache = @local_vertex_normalizer_triangle_pair_object_ids_v2
          object_key = triangle.object_id
          cached = object_cache[object_key]
          if cached && cached[0].equal?(triangle)
            @local_vertex_normalizer_triangle_pair_cache_stats_v2[:triangle_id_hits] += 1
            return cached[1]
          end

          @local_vertex_normalizer_triangle_pair_cache_stats_v2[:triangle_id_misses] += 1
          canonical_key = canonical_triangle_key(triangle).map do |point|
            values = point.respond_to?(:to_a) ? point.to_a : Array(point)
            values.dup.freeze
          end.freeze
          triangle_ids = @local_vertex_normalizer_triangle_pair_triangle_ids_v2
          triangle_id = triangle_ids[canonical_key]
          unless triangle_id
            triangle_id = @local_vertex_normalizer_triangle_pair_next_id_v2
            @local_vertex_normalizer_triangle_pair_next_id_v2 = triangle_id + 1
            triangle_ids[canonical_key] = triangle_id
          end
          object_cache[object_key] = [triangle, triangle_id]
          triangle_id
        end

        def publish_triangle_intersection_pair_result_cache_v2
          stats = @local_vertex_normalizer_triangle_pair_cache_stats_v2
          return unless stats

          cache = @local_vertex_normalizer_triangle_pair_result_cache_v2
          triangle_ids = @local_vertex_normalizer_triangle_pair_triangle_ids_v2
          summary = stats.merge(
            entries: cache&.length.to_i,
            unique_triangles: triangle_ids&.length.to_i,
            saved_exact_predicates: stats[:hits]
          )
          profile = @local_vertex_normalizer_debug_profile
          if profile
            counters = profile[:performance_counters] ||= {}
            counters[:triangle_intersection_pair_result_cache] = summary
          end

          return unless profile && profile[:verbose]
          return unless respond_to?(:debug_profile_log, true)

          hit_rate = stats[:calls].positive? ?
            (100.0 * stats[:hits] / stats[:calls]) : 0.0
          debug_profile_log(
            format(
              'WORK triangle_intersection_pair_result_cache calls=%d hits=%d misses=%d hit_rate=%.2f%% stores=%d entries=%d unique_triangles=%d allowed_hits=%d rejected_hits=%d bypassed_full=%d',
              stats[:calls],
              stats[:hits],
              stats[:misses],
              hit_rate,
              stats[:stores],
              summary[:entries],
              summary[:unique_triangles],
              stats[:allowed_hits],
              stats[:rejected_hits],
              stats[:bypassed_full]
            )
          )
        rescue StandardError
          # Profiling must never change normalization behavior.
          nil
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerTriangleIntersectionPairResultCacheV2 unless
          ancestors.include?(LocalVertexNormalizerTriangleIntersectionPairResultCacheV2)
      end
    end
  end
end
