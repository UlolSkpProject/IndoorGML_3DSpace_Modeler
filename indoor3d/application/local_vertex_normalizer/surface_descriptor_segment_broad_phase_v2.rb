# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Conservative broad phase for the exact collinear-point scan used by the
      # surface-equivalence descriptor. A point can lie on a segment only when it
      # lies inside the segment's exact integer AABB, so candidates outside that
      # box are discarded before the unchanged integer_point_between? predicate.
      module LocalVertexNormalizerSurfaceDescriptorSegmentBroadPhaseV2
        SURFACE_DESCRIPTOR_SEGMENT_BROAD_PHASE_THRESHOLD = 32

        private

        def normalize_entity(entity)
          previous_stats = @local_vertex_normalizer_surface_descriptor_segment_bp_stats_v2
          previous_context = @local_vertex_normalizer_surface_descriptor_segment_bp_context_v2
          @local_vertex_normalizer_surface_descriptor_segment_bp_stats_v2 = {
            owner_calls: 0,
            indexed_owner_calls: 0,
            segment_queries: 0,
            full_candidates: 0,
            narrowed_candidates: 0,
            exact_candidate_tests: 0,
            fallbacks: 0,
            first_fallback_error: nil
          }
          @local_vertex_normalizer_surface_descriptor_segment_bp_context_v2 = nil

          super
        ensure
          stats = @local_vertex_normalizer_surface_descriptor_segment_bp_stats_v2
          emit_surface_descriptor_segment_broad_phase_v2(stats) if stats
          @local_vertex_normalizer_surface_descriptor_segment_bp_stats_v2 = previous_stats
          @local_vertex_normalizer_surface_descriptor_segment_bp_context_v2 = previous_context
        end

        def split_triangle_edge_owners(records)
          stats = @local_vertex_normalizer_surface_descriptor_segment_bp_stats_v2
          return super unless stats

          stats[:owner_calls] += 1
          previous_context = @local_vertex_normalizer_surface_descriptor_segment_bp_context_v2
          @local_vertex_normalizer_surface_descriptor_segment_bp_context_v2 = {
            candidates: nil,
            axes: nil,
            indexed: false
          }
          super
        ensure
          @local_vertex_normalizer_surface_descriptor_segment_bp_context_v2 = previous_context if stats
        end

        def integer_points_on_segment_sorted(point_a, point_b, candidates)
          stats = @local_vertex_normalizer_surface_descriptor_segment_bp_stats_v2
          context = @local_vertex_normalizer_surface_descriptor_segment_bp_context_v2
          return super unless stats && context
          return super if candidates.length < SURFACE_DESCRIPTOR_SEGMENT_BROAD_PHASE_THRESHOLD

          stats[:segment_queries] += 1
          narrowed = surface_descriptor_segment_candidates_v2(
            point_a,
            point_b,
            candidates,
            context,
            stats
          )
          return super unless narrowed

          direction = integer_subtract(point_b, point_a)
          axis = direction.each_index.max_by { |index| direction[index].abs }
          denominator = direction[axis]
          return [point_a, point_b] if denominator.zero?

          stats[:exact_candidate_tests] += narrowed.length
          narrowed.select do |point|
            point == point_a || point == point_b ||
              integer_point_between?(point, point_a, point_b)
          end.sort_by do |point|
            Rational(point[axis] - point_a[axis], denominator)
          end.uniq
        rescue StandardError => error
          surface_descriptor_segment_broad_phase_fallback_v2(stats, error)
          super
        end

        def surface_descriptor_segment_candidates_v2(
          point_a,
          point_b,
          candidates,
          context,
          stats
        )
          index = surface_descriptor_segment_index_v2(candidates, context, stats)
          return nil unless index

          bounds = 3.times.map do |axis|
            [point_a[axis], point_b[axis]].minmax
          end
          ranges = 3.times.map do |axis|
            entries = index[axis]
            first = surface_descriptor_segment_lower_bound_v2(entries, bounds[axis][0])
            last = surface_descriptor_segment_upper_bound_v2(entries, bounds[axis][1])
            [axis, first, last, last - first]
          end
          axis, first, last, = ranges.min_by { |entry| [entry[3], entry[0]] }

          stats[:full_candidates] += candidates.length
          selected = index[axis][first...last].to_a.select do |entry|
            point = entry[2]
            3.times.all? do |candidate_axis|
              point[candidate_axis] >= bounds[candidate_axis][0] &&
                point[candidate_axis] <= bounds[candidate_axis][1]
            end
          end
          narrowed = selected.sort_by { |entry| entry[1] }.map { |entry| entry[2] }
          stats[:narrowed_candidates] += narrowed.length
          narrowed
        end

        def surface_descriptor_segment_index_v2(candidates, context, stats)
          if context[:candidates]&.equal?(candidates) && context[:axes]
            return context[:axes]
          end

          axes = 3.times.map do |axis|
            candidates.each_with_index.map do |point, index|
              [point[axis], index, point]
            end.sort_by { |coordinate, index, _point| [coordinate, index] }
          end

          context[:candidates] = candidates
          context[:axes] = axes
          unless context[:indexed]
            context[:indexed] = true
            stats[:indexed_owner_calls] += 1
          end
          axes
        rescue StandardError => error
          surface_descriptor_segment_broad_phase_fallback_v2(stats, error)
          nil
        end

        def surface_descriptor_segment_lower_bound_v2(entries, value)
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

        def surface_descriptor_segment_upper_bound_v2(entries, value)
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

        def surface_descriptor_segment_broad_phase_fallback_v2(stats, error)
          return unless stats

          stats[:fallbacks] += 1
          stats[:first_fallback_error] ||= {
            class: error.class.to_s,
            message: error.message.to_s,
            backtrace: Array(error.backtrace).first(3)
          }
        end

        def emit_surface_descriptor_segment_broad_phase_v2(stats)
          profile = @local_vertex_normalizer_debug_profile
          return unless profile && profile[:verbose]
          return unless respond_to?(:debug_profile_log, true)

          full = stats[:full_candidates]
          narrowed = stats[:narrowed_candidates]
          reduction = full.positive? ? 100.0 * (full - narrowed) / full : 0.0
          debug_profile_log(
            format(
              'WORK surface_descriptor_segment_broad_phase owner_calls=%d indexed_owner_calls=%d segment_queries=%d full_candidates=%d narrowed_candidates=%d reduction=%.2f%% exact_candidate_tests=%d fallbacks=%d',
              stats[:owner_calls],
              stats[:indexed_owner_calls],
              stats[:segment_queries],
              full,
              narrowed,
              reduction,
              stats[:exact_candidate_tests],
              stats[:fallbacks]
            )
          )

          error = stats[:first_fallback_error]
          if error
            debug_profile_log(
              "WORK surface_descriptor_segment_broad_phase_fallback_error " \
              "#{error[:class]}: #{error[:message]} at=#{error[:backtrace].inspect}"
            )
          end
        rescue StandardError
          nil
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerSurfaceDescriptorSegmentBroadPhaseV2 unless
          ancestors.include?(LocalVertexNormalizerSurfaceDescriptorSegmentBroadPhaseV2)
      end
    end
  end
end
