# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Exact fast path for the common coplanar case where two non-degenerate
      # triangles share one complete edge. In that case their intersection is
      # exactly the shared edge iff the two opposite vertices lie on opposite
      # sides of the shared edge in an exact integer 2D projection.
      #
      # No tolerance is introduced. Any case that does not satisfy the strict
      # preconditions falls back to the established Rational clipping predicate.
      module LocalVertexNormalizerCoplanarSharedEdgeIntersectionFastPath
        private

        def normalize_entity(entity)
          previous_stats = @local_vertex_normalizer_coplanar_shared_edge_fast_path_stats
          @local_vertex_normalizer_coplanar_shared_edge_fast_path_stats = {
            coplanar_calls: 0,
            shared_edge_calls: 0,
            fast_decisions: 0,
            fast_allowed: 0,
            fast_rejected: 0,
            fallbacks: 0,
            first_fallback_error: nil
          }

          super
        ensure
          stats = @local_vertex_normalizer_coplanar_shared_edge_fast_path_stats
          emit_coplanar_shared_edge_intersection_fast_path(stats) if stats
          @local_vertex_normalizer_coplanar_shared_edge_fast_path_stats = previous_stats
        end

        def coplanar_triangle_intersection_allowed?(triangle_a, triangle_b, shared)
          stats = @local_vertex_normalizer_coplanar_shared_edge_fast_path_stats
          return super unless stats

          stats[:coplanar_calls] += 1
          return super unless Array(shared).length == 2

          stats[:shared_edge_calls] += 1
          decision = coplanar_shared_edge_intersection_decision(
            triangle_a,
            triangle_b,
            shared
          )
          if decision.nil?
            stats[:fallbacks] += 1
            return super
          end

          stats[:fast_decisions] += 1
          if decision
            stats[:fast_allowed] += 1
          else
            stats[:fast_rejected] += 1
          end
          decision
        rescue StandardError => error
          coplanar_shared_edge_intersection_fallback(stats, error)
          super
        end

        def coplanar_shared_edge_intersection_decision(triangle_a, triangle_b, shared)
          return nil unless triangle_a.length == 3 && triangle_b.length == 3
          return nil unless shared.length == 2 && shared[0] != shared[1]

          opposite_a = triangle_a.find { |point| point != shared[0] && point != shared[1] }
          opposite_b = triangle_b.find { |point| point != shared[0] && point != shared[1] }
          return nil unless opposite_a && opposite_b

          normal = integer_triangle_normal(triangle_a)
          return nil if integer_zero_vector?(normal)

          drop_axis = normal.each_index.max_by { |axis| normal[axis].abs }
          edge_a = project_integer_point(shared[0], drop_axis)
          edge_b = project_integer_point(shared[1], drop_axis)
          projected_a = project_integer_point(opposite_a, drop_axis)
          projected_b = project_integer_point(opposite_b, drop_axis)

          orientation_a = integer_orientation_2d(edge_a, edge_b, projected_a)
          orientation_b = integer_orientation_2d(edge_a, edge_b, projected_b)
          return nil if orientation_a.zero? || orientation_b.zero?

          orientation_a.positive? != orientation_b.positive?
        end

        def coplanar_shared_edge_intersection_fallback(stats, error)
          return unless stats

          stats[:fallbacks] += 1
          stats[:first_fallback_error] ||= {
            class: error.class.to_s,
            message: error.message.to_s,
            backtrace: Array(error.backtrace).first(3)
          }
        end

        def emit_coplanar_shared_edge_intersection_fast_path(stats)
          profile = @local_vertex_normalizer_diagnostic_profile
          return unless profile && profile[:verbose]
          return unless respond_to?(:diagnostic_profile_log, true)

          shared = stats[:shared_edge_calls]
          fast = stats[:fast_decisions]
          coverage = shared.positive? ? (100.0 * fast / shared) : 0.0
          diagnostic_profile_log(
            format(
              'WORK coplanar_shared_edge_intersection_fast_path coplanar_calls=%d shared_edge_calls=%d fast_decisions=%d coverage=%.2f%% allowed=%d rejected=%d fallbacks=%d',
              stats[:coplanar_calls],
              shared,
              fast,
              coverage,
              stats[:fast_allowed],
              stats[:fast_rejected],
              stats[:fallbacks]
            )
          )

          error = stats[:first_fallback_error]
          if error
            diagnostic_profile_log(
              "WORK coplanar_shared_edge_intersection_fast_path_fallback_error " \
              "#{error[:class]}: #{error[:message]} at=#{error[:backtrace].inspect}"
            )
          end
        rescue StandardError
          nil
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerCoplanarSharedEdgeIntersectionFastPath unless
          ancestors.include?(LocalVertexNormalizerCoplanarSharedEdgeIntersectionFastPath)
      end
    end
  end
end
