# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Reduces conforming segment candidate scans with a conservative spatial
      # broad phase. Only points that are provably outside the segment AABB,
      # expanded by the unchanged exact predicate tolerance, are discarded.
      # Every surviving point still passes through point_on_segment_parameter.
      module LocalVertexNormalizerConformingCandidateBroadPhaseV2
        private

        def conforming_triangle_snapshot(
          source_triangles,
          coordinate_space: :grid,
          duplicate_diagnostics: nil
        )
          previous_context = @local_vertex_normalizer_conforming_broad_phase_v2
          context = {
            coordinate_space: coordinate_space,
            candidates: nil,
            axes: nil,
            index_builds: 0,
            edge_queries: 0,
            segment_queries: 0,
            full_candidate_visits: 0,
            narrowed_candidate_visits: 0,
            fallbacks: 0,
            first_fallback_error: nil
          }
          @local_vertex_normalizer_conforming_broad_phase_v2 = context

          super
        ensure
          if context
            emit_conforming_broad_phase_v2(context)
            @local_vertex_normalizer_conforming_broad_phase_v2 = previous_context
          end
        end

        def conforming_edge_interior_points_in_direction(
          start_point,
          end_point,
          candidates,
          coordinate_space
        )
          context = @local_vertex_normalizer_conforming_broad_phase_v2
          return super unless context

          narrowed = conforming_broad_phase_candidates_v2(
            start_point,
            end_point,
            candidates,
            context,
            coordinate_space
          )
          context[:edge_queries] += 1
          super(start_point, end_point, narrowed, coordinate_space)
        end

        def segment_has_interior_candidate?(
          start_point,
          end_point,
          candidates,
          coordinate_space: :grid
        )
          context = @local_vertex_normalizer_conforming_broad_phase_v2
          return super unless context

          narrowed = conforming_broad_phase_candidates_v2(
            start_point,
            end_point,
            candidates,
            context,
            coordinate_space
          )
          context[:segment_queries] += 1
          super(
            start_point,
            end_point,
            narrowed,
            coordinate_space: coordinate_space
          )
        end

        def conforming_broad_phase_candidates_v2(
          start_point,
          end_point,
          candidates,
          context,
          coordinate_space
        )
          context[:full_candidate_visits] += candidates.length
          index = conforming_candidate_index_v2(candidates, context, coordinate_space)
          unless index
            context[:fallbacks] += 1
            context[:narrowed_candidate_visits] += candidates.length
            return candidates
          end

          tolerance_in =
            LocalVertexNormalizer::GRID_EPSILON_MM /
            LocalVertexNormalizer::MM_PER_INCH
          bounds = 3.times.map do |axis|
            start_value = point_coordinate(start_point, axis)
            end_value = point_coordinate(end_point, axis)
            minimum, maximum = [start_value, end_value].minmax
            [minimum - tolerance_in, maximum + tolerance_in]
          end

          ranges = 3.times.map do |axis|
            entries = index[axis]
            first = conforming_axis_lower_bound_v2(entries, bounds[axis][0])
            last = conforming_axis_upper_bound_v2(entries, bounds[axis][1])
            [axis, first, last, last - first]
          end
          axis, first, last, = ranges.min_by { |entry| [entry[3], entry[0]] }

          selected = index[axis][first...last].to_a.select do |entry|
            point = entry[2]
            3.times.all? do |candidate_axis|
              value = point_coordinate(point, candidate_axis)
              value >= bounds[candidate_axis][0] && value <= bounds[candidate_axis][1]
            end
          end

          # Preserve the original candidate order even though current downstream
          # predicates are order-insensitive before their own parameter sort/any?.
          narrowed = selected.sort_by { |entry| entry[1] }.map { |entry| entry[2] }
          context[:narrowed_candidate_visits] += narrowed.length
          narrowed
        rescue StandardError => error
          context[:fallbacks] += 1
          context[:first_fallback_error] ||= {
            class: error.class.to_s,
            message: error.message.to_s,
            backtrace: Array(error.backtrace).first(3)
          }
          context[:narrowed_candidate_visits] += candidates.length
          candidates
        end

        def conforming_candidate_index_v2(candidates, context, coordinate_space)
          if context[:candidates]&.equal?(candidates) &&
             context[:coordinate_space] == coordinate_space &&
             context[:axes]
            return context[:axes]
          end

          axes = 3.times.map do |axis|
            candidates.each_with_index.map do |point, index|
              coordinate = point_coordinate(point, axis)
              return nil unless coordinate.finite?

              [coordinate, index, point]
            end.sort_by { |coordinate, index, _point| [coordinate, index] }
          end

          context[:candidates] = candidates
          context[:coordinate_space] = coordinate_space
          context[:axes] = axes
          context[:index_builds] += 1
          axes
        end

        def conforming_axis_lower_bound_v2(entries, value)
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

        def conforming_axis_upper_bound_v2(entries, value)
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

        def emit_conforming_broad_phase_v2(context)
          profile = @local_vertex_normalizer_debug_profile
          return unless profile && profile[:verbose]
          return unless respond_to?(:debug_profile_log, true)

          full = context[:full_candidate_visits]
          narrowed = context[:narrowed_candidate_visits]
          reduction = full.positive? ? 100.0 * (full - narrowed) / full : 0.0
          debug_profile_log(
            format(
              'WORK conforming_broad_phase_%s index_builds=%d edge_queries=%d segment_queries=%d full_candidates=%d narrowed_candidates=%d reduction=%.2f%% fallbacks=%d',
              context[:coordinate_space],
              context[:index_builds],
              context[:edge_queries],
              context[:segment_queries],
              full,
              narrowed,
              reduction,
              context[:fallbacks]
            )
          )
          error = context[:first_fallback_error]
          if error
            debug_profile_log(
              "WORK conforming_broad_phase_fallback_error " \
              "#{error[:class]}: #{error[:message]} at=#{error[:backtrace].inspect}"
            )
          end
        rescue StandardError
          nil
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerConformingCandidateBroadPhaseV2 unless
          ancestors.include?(LocalVertexNormalizerConformingCandidateBroadPhaseV2)
      end
    end
  end
end
