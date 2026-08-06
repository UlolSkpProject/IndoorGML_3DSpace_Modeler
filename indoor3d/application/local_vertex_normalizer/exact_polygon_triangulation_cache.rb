# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Reuses deterministic exact polygon triangulations only when the complete
      # ordered input is identical within one normalize_entity call. Geometry
      # validation remains outside this cache and is therefore rerun normally.
      module LocalVertexNormalizerExactPolygonTriangulationCache
        private

        def normalize_entity(entity)
          previous_cache = @local_vertex_normalizer_exact_polygon_cache
          previous_stats = @local_vertex_normalizer_exact_polygon_cache_stats
          @local_vertex_normalizer_exact_polygon_cache = {}
          @local_vertex_normalizer_exact_polygon_cache_stats = {
            hits: 0,
            misses: 0,
            stored_triangle_count: 0
          }

          super
        ensure
          stats = @local_vertex_normalizer_exact_polygon_cache_stats
          if stats && @local_vertex_normalizer_diagnostic_profile &&
             respond_to?(:diagnostic_profile_log, true)
            diagnostic_profile_log(
              "WORK exact_polygon_cache hits=#{stats[:hits]} " \
              "misses=#{stats[:misses]} " \
              "entries=#{@local_vertex_normalizer_exact_polygon_cache&.length.to_i} " \
              "stored_triangles=#{stats[:stored_triangle_count]}"
            )
          end
          @local_vertex_normalizer_exact_polygon_cache = previous_cache
          @local_vertex_normalizer_exact_polygon_cache_stats = previous_stats
        end

        def triangulate_exact_polygon_with_holes(outer, holes, drop_axis)
          cache = @local_vertex_normalizer_exact_polygon_cache
          stats = @local_vertex_normalizer_exact_polygon_cache_stats
          return super unless cache && stats

          key = exact_polygon_ordered_cache_key(outer, holes, drop_axis)
          cached = cache[key]
          if cached
            stats[:hits] += 1
            return exact_polygon_cached_triangles_dup(cached)
          end

          stats[:misses] += 1
          triangles = super
          stored = exact_polygon_cached_triangles_copy(triangles)
          cache[key] = stored
          stats[:stored_triangle_count] += stored.length
          triangles
        end

        def exact_polygon_ordered_cache_key(outer, holes, drop_axis)
          [
            drop_axis,
            exact_polygon_ordered_loop_key(outer),
            Array(holes).map { |hole| exact_polygon_ordered_loop_key(hole) }.freeze
          ].freeze
        end

        def exact_polygon_ordered_loop_key(loop)
          Array(loop).map do |point|
            Array(point).map { |coordinate| coordinate }.freeze
          end.freeze
        end

        def exact_polygon_cached_triangles_copy(triangles)
          Array(triangles).map do |triangle|
            Array(triangle).map do |point|
              Array(point).map { |coordinate| coordinate }.freeze
            end.freeze
          end.freeze
        end

        def exact_polygon_cached_triangles_dup(cached)
          cached.map do |triangle|
            triangle.map { |point| point.dup }
          end
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerExactPolygonTriangulationCache unless
          ancestors.include?(LocalVertexNormalizerExactPolygonTriangulationCache)
      end
    end
  end
end
