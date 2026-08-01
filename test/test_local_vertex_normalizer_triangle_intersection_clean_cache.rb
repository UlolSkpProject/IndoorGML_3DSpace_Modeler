# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        attr_reader :base_collect_calls

        def initialize(result_factory)
          @result_factory = result_factory
          @base_collect_calls = 0
        end

        private

        def collect_triangle_intersection_failures(triangles, partition_ids: nil)
          @base_collect_calls += 1
          @result_factory.call(triangles, partition_ids)
        end

        def canonical_triangle_key(triangle)
          triangle.sort
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/triangle_intersection_clean_cache_v2'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerTriangleIntersectionCleanCacheTest < Minitest::Test
        CachePolicy = LocalVertexNormalizerTriangleIntersectionCleanCacheV2

        def test_minimum_triangle_threshold_is_eight
          assert_equal 8, CachePolicy::TRIANGLE_INTERSECTION_CLEAN_CACHE_MIN_TRIANGLES
        end

        def test_clean_eight_triangle_mesh_is_cached
          normalizer = build_normalizer do |_triangles, _partition_ids|
            { tested_pairs: 17, pairs: [] }
          end
          triangles = triangle_set(8)

          first = normalizer.send(:collect_triangle_intersection_failures, triangles)
          second = normalizer.send(:collect_triangle_intersection_failures, triangles)
          stats = cache_stats(normalizer)

          assert_equal first, second
          assert_equal 1, normalizer.base_collect_calls
          assert_equal 1, stats[:misses]
          assert_equal 1, stats[:stores]
          assert_equal 1, stats[:hits]
          assert_equal 17, stats[:saved_tested_pairs]
          assert_empty second[:pairs]
        end

        def test_invalid_result_is_never_cached
          normalizer = build_normalizer do |_triangles, _partition_ids|
            { tested_pairs: 1, pairs: [[0, 1]] }
          end
          triangles = triangle_set(8)

          first = normalizer.send(:collect_triangle_intersection_failures, triangles)
          second = normalizer.send(:collect_triangle_intersection_failures, triangles)
          stats = cache_stats(normalizer)

          assert_equal [[0, 1]], first[:pairs]
          assert_equal first, second
          assert_equal 2, normalizer.base_collect_calls
          assert_equal 2, stats[:misses]
          assert_equal 0, stats[:stores]
          assert_equal 0, stats[:hits]
        end

        def test_mesh_below_threshold_bypasses_cache
          normalizer = build_normalizer do |_triangles, _partition_ids|
            { tested_pairs: 3, pairs: [] }
          end
          triangles = triangle_set(7)

          normalizer.send(:collect_triangle_intersection_failures, triangles)
          normalizer.send(:collect_triangle_intersection_failures, triangles)
          stats = cache_stats(normalizer)

          assert_equal 2, normalizer.base_collect_calls
          assert_equal 2, stats[:bypassed_small]
          assert_equal 0, stats[:misses]
          assert_equal 0, stats[:stores]
          assert_equal 0, stats[:hits]
        end

        private

        def build_normalizer(&result_factory)
          normalizer = LocalVertexNormalizer.new(result_factory)
          normalizer.instance_variable_set(
            :@local_vertex_normalizer_triangle_intersection_clean_cache_v2,
            {}
          )
          normalizer.instance_variable_set(
            :@local_vertex_normalizer_triangle_intersection_clean_cache_order_v2,
            []
          )
          normalizer.instance_variable_set(
            :@local_vertex_normalizer_triangle_intersection_clean_cache_stats_v2,
            {
              hits: 0,
              misses: 0,
              stores: 0,
              evictions: 0,
              bypassed_small: 0,
              bypassed_partitioned: 0,
              saved_tested_pairs: 0
            }
          )
          normalizer
        end

        def cache_stats(normalizer)
          normalizer.instance_variable_get(
            :@local_vertex_normalizer_triangle_intersection_clean_cache_stats_v2
          )
        end

        def triangle_set(count)
          Array.new(count) do |index|
            [
              [index, 0, 0],
              [index, 1, 0],
              [index, 0, 1]
            ]
          end
        end
      end
    end
  end
end
