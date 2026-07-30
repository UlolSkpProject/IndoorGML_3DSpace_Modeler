# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Conservative broad phase for exact ear clipping.
      #
      # The existing ear predicate remains authoritative. This wrapper only skips
      # point/edge predicates when exact integer 2D AABBs prove that the candidate
      # cannot lie in the ear triangle or intersect the proposed diagonal.
      module LocalVertexNormalizerExactPolygonEarBroadPhaseV2
        EXACT_POLYGON_EAR_BROAD_PHASE_THRESHOLD = 24

        private

        def normalize_entity(entity)
          previous_stats = @local_vertex_normalizer_exact_ear_broad_phase_stats_v2
          stats = {
            triangulations: 0,
            indexed_iterations: 0,
            ear_calls: 0,
            point_full_candidates: 0,
            point_narrowed_candidates: 0,
            edge_full_candidates: 0,
            edge_narrowed_candidates: 0,
            exact_point_tests: 0,
            exact_segment_tests: 0,
            fallbacks: 0,
            first_fallback_error: nil
          }
          @local_vertex_normalizer_exact_ear_broad_phase_stats_v2 = stats

          super
        ensure
          if stats
            emit_exact_polygon_ear_broad_phase_v2(stats)
            @local_vertex_normalizer_exact_ear_broad_phase_stats_v2 = previous_stats
          end
        end

        def triangulate_exact_weak_polygon(points, drop_axis)
          stats = @local_vertex_normalizer_exact_ear_broad_phase_stats_v2
          return super unless stats

          previous_context = @local_vertex_normalizer_exact_ear_broad_phase_context_v2
          context = {
            projected: nil,
            length: nil,
            index: nil
          }
          @local_vertex_normalizer_exact_ear_broad_phase_context_v2 = context
          stats[:triangulations] += 1

          super
        ensure
          if stats
            @local_vertex_normalizer_exact_ear_broad_phase_context_v2 = previous_context
          end
        end

        def exact_polygon_ear?(polygon, index, drop_axis, projected: nil)
          stats = @local_vertex_normalizer_exact_ear_broad_phase_stats_v2
          context = @local_vertex_normalizer_exact_ear_broad_phase_context_v2
          return super unless stats && context && projected
          return super if polygon.length < EXACT_POLYGON_EAR_BROAD_PHASE_THRESHOLD

          stats[:ear_calls] += 1
          broad_phase = exact_polygon_ear_broad_phase_index_v2(projected, context, stats)
          return super unless broad_phase

          previous_index = (index - 1) % polygon.length
          following_index = (index + 1) % polygon.length
          point_a = projected[previous_index]
          point_b = projected[index]
          point_c = projected[following_index]
          return false unless integer_orientation_2d(point_a, point_b, point_c).positive?

          triangle_bounds = exact_polygon_ear_bounds_2d_v2([point_a, point_b, point_c])
          point_indices = exact_polygon_ear_point_candidates_v2(
            broad_phase,
            triangle_bounds,
            stats
          )
          point_indices.each do |candidate_index|
            next if candidate_index == previous_index ||
                    candidate_index == index ||
                    candidate_index == following_index

            candidate = projected[candidate_index]
            next if candidate == point_a || candidate == point_b || candidate == point_c

            stats[:exact_point_tests] += 1
            return false if integer_point_in_triangle_2d?(
              candidate,
              point_a,
              point_b,
              point_c
            )
          end

          diagonal_bounds = exact_polygon_ear_bounds_2d_v2([point_a, point_c])
          edge_indices = exact_polygon_ear_edge_candidates_v2(
            broad_phase,
            diagonal_bounds,
            stats
          )
          edge_indices.each do |edge_index|
            edge_following = (edge_index + 1) % polygon.length
            next if edge_index == previous_index || edge_index == index
            next if edge_following == previous_index || edge_following == following_index

            edge_a = projected[edge_index]
            edge_b = projected[edge_following]
            next if edge_a == point_a || edge_b == point_a ||
                    edge_a == point_c || edge_b == point_c

            stats[:exact_segment_tests] += 1
            return false if integer_segments_intersect_2d?(
              point_a,
              point_c,
              edge_a,
              edge_b
            )
          end

          true
        rescue StandardError => error
          exact_polygon_ear_broad_phase_fallback_v2(stats, error)
          super
        end

        def exact_polygon_ear_broad_phase_index_v2(projected, context, stats)
          if context[:projected]&.equal?(projected) &&
             context[:length] == projected.length &&
             context[:index]
            return context[:index]
          end

          point_axes = 2.times.map do |axis|
            projected.each_with_index.map do |point, point_index|
              [point[axis], point_index]
            end.sort_by { |coordinate, point_index| [coordinate, point_index] }
          end

          edge_bounds = projected.each_index.map do |edge_index|
            following_index = (edge_index + 1) % projected.length
            exact_polygon_ear_bounds_2d_v2(
              [projected[edge_index], projected[following_index]]
            )
          end

          edge_min_axes = 2.times.map do |axis|
            edge_bounds.each_with_index.map do |bounds, edge_index|
              [bounds[axis][0], bounds[axis][1], edge_index]
            end.sort_by { |minimum, maximum, edge_index| [minimum, maximum, edge_index] }
          end
          edge_max_axes = 2.times.map do |axis|
            edge_bounds.each_with_index.map do |bounds, edge_index|
              [bounds[axis][1], bounds[axis][0], edge_index]
            end.sort_by { |maximum, minimum, edge_index| [maximum, minimum, edge_index] }
          end

          index = {
            projected: projected,
            point_axes: point_axes,
            edge_bounds: edge_bounds,
            edge_min_axes: edge_min_axes,
            edge_max_axes: edge_max_axes
          }
          context[:projected] = projected
          context[:length] = projected.length
          context[:index] = index
          stats[:indexed_iterations] += 1
          index
        rescue StandardError => error
          exact_polygon_ear_broad_phase_fallback_v2(stats, error)
          nil
        end

        def exact_polygon_ear_point_candidates_v2(index, bounds, stats)
          point_axes = index.fetch(:point_axes)
          ranges = 2.times.map do |axis|
            entries = point_axes[axis]
            first = exact_polygon_ear_lower_bound_v2(entries, bounds[axis][0])
            last = exact_polygon_ear_upper_bound_v2(entries, bounds[axis][1])
            [axis, first, last, last - first]
          end
          axis, first, last, = ranges.min_by { |entry| [entry[3], entry[0]] }

          stats[:point_full_candidates] += point_axes[0].length
          candidates = point_axes[axis][first...last].to_a.map { |_coordinate, point_index| point_index }

          projected = index.fetch(:projected)
          narrowed = candidates.select do |point_index|
            point = projected[point_index]
            point[0] >= bounds[0][0] && point[0] <= bounds[0][1] &&
              point[1] >= bounds[1][0] && point[1] <= bounds[1][1]
          end.sort
          stats[:point_narrowed_candidates] += narrowed.length
          narrowed
        end

        def exact_polygon_ear_edge_candidates_v2(index, bounds, stats)
          edge_count = index.fetch(:edge_bounds).length
          options = []

          2.times do |axis|
            min_entries = index.fetch(:edge_min_axes)[axis]
            prefix_end = exact_polygon_ear_upper_bound_v2(min_entries, bounds[axis][1])
            options << [:prefix, axis, 0, prefix_end, prefix_end]

            max_entries = index.fetch(:edge_max_axes)[axis]
            suffix_start = exact_polygon_ear_lower_bound_v2(max_entries, bounds[axis][0])
            options << [:suffix, axis, suffix_start, edge_count, edge_count - suffix_start]
          end

          mode, axis, first, last, = options.min_by do |entry|
            [entry[4], entry[1], entry[0] == :prefix ? 0 : 1]
          end
          entries = if mode == :prefix
                      index.fetch(:edge_min_axes)[axis]
                    else
                      index.fetch(:edge_max_axes)[axis]
                    end

          stats[:edge_full_candidates] += edge_count
          candidate_indices = entries[first...last].to_a.map { |entry| entry[2] }
          edge_bounds = index.fetch(:edge_bounds)
          narrowed = candidate_indices.select do |edge_index|
            candidate = edge_bounds[edge_index]
            exact_polygon_ear_bounds_overlap_2d_v2?(candidate, bounds)
          end.uniq.sort
          stats[:edge_narrowed_candidates] += narrowed.length
          narrowed
        end

        def exact_polygon_ear_bounds_2d_v2(points)
          x_values = points.map { |point| point[0] }
          y_values = points.map { |point| point[1] }
          [x_values.minmax, y_values.minmax]
        end

        def exact_polygon_ear_bounds_overlap_2d_v2?(first, second)
          first[0][0] <= second[0][1] && first[0][1] >= second[0][0] &&
            first[1][0] <= second[1][1] && first[1][1] >= second[1][0]
        end

        def exact_polygon_ear_lower_bound_v2(entries, value)
          low = 0
          high = entries.length
          while low < high
            middle = (low + high) / 2
            if entries[middle][0] < value
              low = middle + 1
            else
              high = middle
            end
          end
          low
        end

        def exact_polygon_ear_upper_bound_v2(entries, value)
          low = 0
          high = entries.length
          while low < high
            middle = (low + high) / 2
            if entries[middle][0] <= value
              low = middle + 1
            else
              high = middle
            end
          end
          low
        end

        def exact_polygon_ear_broad_phase_fallback_v2(stats, error)
          return unless stats

          stats[:fallbacks] += 1
          stats[:first_fallback_error] ||= {
            class: error.class.to_s,
            message: error.message.to_s,
            backtrace: Array(error.backtrace).first(3)
          }
        end

        def emit_exact_polygon_ear_broad_phase_v2(stats)
          profile = @local_vertex_normalizer_debug_profile
          return unless profile && profile[:verbose]
          return unless respond_to?(:debug_profile_log, true)

          point_full = stats[:point_full_candidates]
          point_narrowed = stats[:point_narrowed_candidates]
          point_reduction = point_full.positive? ?
            100.0 * (point_full - point_narrowed) / point_full : 0.0
          edge_full = stats[:edge_full_candidates]
          edge_narrowed = stats[:edge_narrowed_candidates]
          edge_reduction = edge_full.positive? ?
            100.0 * (edge_full - edge_narrowed) / edge_full : 0.0

          debug_profile_log(
            format(
              'WORK exact_polygon_ear_broad_phase triangulations=%d indexed_iterations=%d ear_calls=%d point_full=%d point_narrowed=%d point_reduction=%.2f%% edge_full=%d edge_narrowed=%d edge_reduction=%.2f%% exact_point_tests=%d exact_segment_tests=%d fallbacks=%d',
              stats[:triangulations],
              stats[:indexed_iterations],
              stats[:ear_calls],
              point_full,
              point_narrowed,
              point_reduction,
              edge_full,
              edge_narrowed,
              edge_reduction,
              stats[:exact_point_tests],
              stats[:exact_segment_tests],
              stats[:fallbacks]
            )
          )

          error = stats[:first_fallback_error]
          if error
            debug_profile_log(
              "WORK exact_polygon_ear_broad_phase_fallback_error " \
              "#{error[:class]}: #{error[:message]} at=#{error[:backtrace].inspect}"
            )
          end
        rescue StandardError
          nil
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerExactPolygonEarBroadPhaseV2 unless
          ancestors.include?(LocalVertexNormalizerExactPolygonEarBroadPhaseV2)
      end
    end
  end
end
