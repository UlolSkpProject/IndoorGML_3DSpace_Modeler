# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Exact integer fast paths for coplanar triangle pairs whose permitted
      # intersection is either empty or one shared vertex.
      #
      # The layer is deliberately one-sided: it returns true only when exact
      # integer predicates prove that the triangles intersect no more than the
      # expected simplex. Every overlap, non-vertex touch, collinear ambiguity,
      # or unexpected input falls back to the established Rational clipping
      # predicate. Invalid geometry is therefore never accepted by this layer.
      module LocalVertexNormalizerCoplanarDisjointSharedVertexFastPathV2
        private

        def normalize_entity(entity)
          previous_stats =
            @local_vertex_normalizer_coplanar_simplex_fast_path_stats_v2
          @local_vertex_normalizer_coplanar_simplex_fast_path_stats_v2 = {
            coplanar_calls: 0,
            disjoint_calls: 0,
            shared_vertex_calls: 0,
            fast_allowed: 0,
            disjoint_fast_allowed: 0,
            shared_vertex_fast_allowed: 0,
            fallbacks: 0,
            first_fallback_error: nil
          }

          super
        ensure
          stats = @local_vertex_normalizer_coplanar_simplex_fast_path_stats_v2
          emit_coplanar_simplex_fast_path_v2(stats) if stats
          @local_vertex_normalizer_coplanar_simplex_fast_path_stats_v2 =
            previous_stats
        end

        def coplanar_triangle_intersection_allowed?(
          triangle_a,
          triangle_b,
          shared
        )
          stats = @local_vertex_normalizer_coplanar_simplex_fast_path_stats_v2
          return super unless stats

          stats[:coplanar_calls] += 1
          shared_count = Array(shared).length
          decision = nil

          case shared_count
          when 0
            stats[:disjoint_calls] += 1
            decision = coplanar_disjoint_intersection_decision_v2(
              triangle_a,
              triangle_b
            )
            stats[:disjoint_fast_allowed] += 1 if decision
          when 1
            stats[:shared_vertex_calls] += 1
            decision = coplanar_shared_vertex_intersection_decision_v2(
              triangle_a,
              triangle_b,
              shared.first
            )
            stats[:shared_vertex_fast_allowed] += 1 if decision
          end

          if decision
            stats[:fast_allowed] += 1
            return true
          end

          stats[:fallbacks] += 1
          super
        rescue StandardError => error
          coplanar_simplex_fast_path_fallback_v2(stats, error)
          super
        end

        # For two convex triangles with no shared vertex, the separating-axis
        # theorem guarantees that every truly disjoint pair is separated by an
        # edge line of one triangle. The separation must be strict: a zero value
        # is a non-shared touch and must remain an invalid intersection.
        def coplanar_disjoint_intersection_decision_v2(triangle_a, triangle_b)
          projected = coplanar_simplex_projection_v2(triangle_a, triangle_b)
          return nil unless projected

          projected_a, projected_b = projected
          return true if coplanar_strict_edge_separation_v2?(
            projected_a,
            projected_b
          )

          nil
        end

        # Proves that two triangles sharing exactly one vertex meet only at that
        # vertex. Any additional segment contact, vertex containment, or edge
        # crossing is left to the Rational reference predicate.
        def coplanar_shared_vertex_intersection_decision_v2(
          triangle_a,
          triangle_b,
          shared_vertex
        )
          projected = coplanar_simplex_projection_v2(triangle_a, triangle_b)
          return nil unless projected

          projected_a, projected_b, drop_axis = projected
          shared = project_integer_point(shared_vertex, drop_axis)
          return nil unless projected_a.count(shared) == 1
          return nil unless projected_b.count(shared) == 1

          projected_a.each do |point|
            next if point == shared
            return nil if integer_point_in_triangle_2d?(
              point,
              projected_b[0],
              projected_b[1],
              projected_b[2]
            )
          end
          projected_b.each do |point|
            next if point == shared
            return nil if integer_point_in_triangle_2d?(
              point,
              projected_a[0],
              projected_a[1],
              projected_a[2]
            )
          end

          edges_a = coplanar_triangle_edges_2d_v2(projected_a)
          edges_b = coplanar_triangle_edges_2d_v2(projected_b)
          edges_a.each do |edge_a|
            edges_b.each do |edge_b|
              next unless integer_segments_intersect_2d?(
                edge_a[0],
                edge_a[1],
                edge_b[0],
                edge_b[1]
              )
              return nil unless coplanar_edges_contact_only_at_shared_vertex_v2?(
                edge_a,
                edge_b,
                shared
              )
            end
          end

          true
        end

        def coplanar_simplex_projection_v2(triangle_a, triangle_b)
          return nil unless triangle_a.length == 3 && triangle_b.length == 3
          return nil unless triangle_a.uniq.length == 3 && triangle_b.uniq.length == 3

          normal = integer_triangle_normal(triangle_a)
          return nil if integer_zero_vector?(normal)

          drop_axis = normal.each_index.max_by { |axis| normal[axis].abs }
          projected_a = triangle_a.map do |point|
            project_integer_point(point, drop_axis)
          end
          projected_b = triangle_b.map do |point|
            project_integer_point(point, drop_axis)
          end
          return nil if integer_orientation_2d(*projected_a).zero?
          return nil if integer_orientation_2d(*projected_b).zero?

          [projected_a, projected_b, drop_axis]
        end

        def coplanar_strict_edge_separation_v2?(triangle_a, triangle_b)
          [
            [triangle_a, triangle_b],
            [triangle_b, triangle_a]
          ].each do |owner, other|
            3.times do |index|
              edge_a = owner[index]
              edge_b = owner[(index + 1) % 3]
              owner_opposite = owner[(index + 2) % 3]
              owner_side = integer_orientation_2d(
                edge_a,
                edge_b,
                owner_opposite
              )
              next if owner_side.zero?

              other_sides = other.map do |point|
                integer_orientation_2d(edge_a, edge_b, point)
              end
              if owner_side.positive?
                return true if other_sides.all?(&:negative?)
              else
                return true if other_sides.all?(&:positive?)
              end
            end
          end

          false
        end

        def coplanar_triangle_edges_2d_v2(triangle)
          3.times.map do |index|
            [triangle[index], triangle[(index + 1) % 3]]
          end
        end

        def coplanar_edges_contact_only_at_shared_vertex_v2?(
          edge_a,
          edge_b,
          shared
        )
          return false unless edge_a.include?(shared) && edge_b.include?(shared)

          opposite_a = edge_a[0] == shared ? edge_a[1] : edge_a[0]
          opposite_b = edge_b[0] == shared ? edge_b[1] : edge_b[0]
          orientation = integer_orientation_2d(
            shared,
            opposite_a,
            opposite_b
          )
          return true unless orientation.zero?

          direction_a = integer_subtract_2d(opposite_a, shared)
          direction_b = integer_subtract_2d(opposite_b, shared)
          integer_dot_2d(direction_a, direction_b).negative?
        end

        def coplanar_simplex_fast_path_fallback_v2(stats, error)
          return unless stats

          stats[:fallbacks] += 1
          stats[:first_fallback_error] ||= {
            class: error.class.to_s,
            message: error.message.to_s,
            backtrace: Array(error.backtrace).first(3)
          }
        end

        def emit_coplanar_simplex_fast_path_v2(stats)
          profile = @local_vertex_normalizer_debug_profile
          return unless profile && profile[:verbose]
          return unless respond_to?(:debug_profile_log, true)

          eligible = stats[:disjoint_calls] + stats[:shared_vertex_calls]
          fast = stats[:fast_allowed]
          coverage = eligible.positive? ? (100.0 * fast / eligible) : 0.0
          debug_profile_log(
            format(
              'WORK coplanar_disjoint_shared_vertex_fast_path coplanar_calls=%d eligible=%d fast_allowed=%d coverage=%.2f%% disjoint_calls=%d disjoint_allowed=%d shared_vertex_calls=%d shared_vertex_allowed=%d fallbacks=%d',
              stats[:coplanar_calls],
              eligible,
              fast,
              coverage,
              stats[:disjoint_calls],
              stats[:disjoint_fast_allowed],
              stats[:shared_vertex_calls],
              stats[:shared_vertex_fast_allowed],
              stats[:fallbacks]
            )
          )

          error = stats[:first_fallback_error]
          if error
            debug_profile_log(
              "WORK coplanar_disjoint_shared_vertex_fast_path_fallback_error " \
              "#{error[:class]}: #{error[:message]} at=#{error[:backtrace].inspect}"
            )
          end
        rescue StandardError
          nil
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerCoplanarDisjointSharedVertexFastPathV2 unless
          ancestors.include?(
            LocalVertexNormalizerCoplanarDisjointSharedVertexFastPathV2
          )
      end
    end
  end
end
