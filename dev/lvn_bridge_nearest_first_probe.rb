# frozen_string_literal: true

require 'time'

base_probe_path = File.join(__dir__, 'lvn_large_solid_face_detail_log_probe.rb')
unless defined?(
  ULOL::Indoor3DGmlModeler::IndoorCore::LvnLargeSolidFaceDetailLogProbe
)
  source = File.binread(base_probe_path).force_encoding(Encoding::UTF_8)
  pattern = %r{
    \n\s*reset_progress\s*\n\s*BASE\.run\s*\n\s*end\s*\n\s*end\s*\n\s*end\s*\n\s*end\s*\z
  }mx
  replacement = <<~'TAIL'

        reset_progress
      end
    end
  end
end
  TAIL
  stripped = source.sub(pattern, replacement)
  raise "Could not suppress default run in #{base_probe_path}" if stripped == source

  TOPLEVEL_BINDING.eval(stripped, base_probe_path, 1)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnBridgeNearestFirstProbe
        BASE = LvnLargeSolidDetailedLogProbe
        DETAIL = LvnLargeSolidFaceDetailLogProbe
        EAR_PROGRESS_INTERVAL = 100

        module_function

        def log(event, data = {}, level: 'INFO')
          BASE.active_context&.log(event, data, level: level)
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        module NearestFirstBridge
          private

          def bridge_exact_hole(polygon, hole, outer_2d, holes_2d, drop_axis)
            hole_index = hole.each_index.max_by do |index|
              point = integer_project_2d(hole[index], drop_axis)
              [point[0], -point[1]]
            end
            hole_point = hole[hole_index]
            hole_point_2d = integer_project_2d(hole_point, drop_axis)
            polygon_2d = polygon.map do |point|
              integer_project_2d(point, drop_axis)
            end
            all_loops = [polygon_2d] + holes_2d

            ordered_candidates = polygon.each_index.filter_map do |polygon_index|
              polygon_point_2d = polygon_2d[polygon_index]
              next if polygon_point_2d == hole_point_2d

              delta = integer_subtract_2d(
                polygon_point_2d,
                hole_point_2d
              )
              [
                integer_dot_2d(delta, delta),
                polygon_index,
                polygon_point_2d
              ]
            end.sort_by do |distance_squared, polygon_index, _point|
              [distance_squared, polygon_index]
            end

            visibility_calls = 0
            selected = ordered_candidates.find do |_distance_squared, _polygon_index, point_2d|
              visibility_calls += 1
              exact_bridge_visible?(
                hole_point_2d,
                point_2d,
                all_loops,
                outer_2d,
                holes_2d
              )
            end

            unless selected
              raise ReconstructionError,
                    'Could not connect an exact coplanar patch hole to its exterior boundary'
            end

            distance_squared, polygon_index, = selected
            LvnBridgeNearestFirstProbe.log(
              'NEAREST_FIRST_BRIDGE_SELECTED',
              {
                polygon_vertex_count: polygon.length,
                hole_vertex_count: hole.length,
                candidate_count: ordered_candidates.length,
                visibility_calls: visibility_calls,
                selected_polygon_index: polygon_index,
                selected_distance_squared: distance_squared
              }
            )

            polygon_point = polygon[polygon_index]
            rotated_hole = hole[hole_index..] + hole[0...hole_index]
            polygon[0..polygon_index] +
              rotated_hole +
              [hole_point, polygon_point] +
              Array(polygon[(polygon_index + 1)..])
          end
        end

        # Exact-equivalent ear selection order for the dev probe.
        #
        # Production currently validates every index first, then chooses the valid
        # ear with maximum exact quality. This probe computes the same exact quality
        # ordering first and stops at the first valid ear. Equal-quality ties retain
        # the lower polygon index, matching Enumerable#max_by over ascending indices.
        module QualityFirstEarTriangulation
          private

          def triangulate_exact_weak_polygon(points, drop_axis)
            started_at = LvnBridgeNearestFirstProbe.monotonic_time
            remaining = points.dup
            projected = remaining.map do |point|
              integer_project_2d(point, drop_axis)
            end
            triangles = []
            limit = remaining.length * remaining.length * 2
            attempts = 0
            initial_vertex_count = remaining.length
            total_ordered_candidates = 0
            total_exact_ear_calls = 0
            max_exact_ear_calls = 0

            LvnBridgeNearestFirstProbe.log(
              'QUALITY_FIRST_EAR_BEGIN',
              {
                initial_vertex_count: initial_vertex_count,
                drop_axis: drop_axis
              }
            )

            while remaining.length > 3
              ordered_candidates = remaining.each_index.filter_map do |index|
                previous_index = (index - 1) % remaining.length
                following_index = (index + 1) % remaining.length
                point_a = projected[previous_index]
                point_b = projected[index]
                point_c = projected[following_index]
                next unless integer_orientation_2d(
                  point_a,
                  point_b,
                  point_c
                ).positive?

                [
                  exact_polygon_ear_quality(
                    remaining,
                    index,
                    drop_axis,
                    projected: projected
                  ),
                  index
                ]
              end.sort_by do |quality, index|
                [-quality, index]
              end

              exact_ear_calls = 0
              selected = ordered_candidates.find do |_quality, index|
                exact_ear_calls += 1
                exact_polygon_ear?(
                  remaining,
                  index,
                  drop_axis,
                  projected: projected
                )
              end

              unless selected
                raise ReconstructionError,
                      "Could not triangulate exact coplanar patch boundary: " \
                      "#{remaining.inspect}"
              end

              selected_quality, ear_index = selected
              total_ordered_candidates += ordered_candidates.length
              total_exact_ear_calls += exact_ear_calls
              max_exact_ear_calls = [max_exact_ear_calls, exact_ear_calls].max

              previous_point = remaining[(ear_index - 1) % remaining.length]
              current_point = remaining[ear_index]
              following_point = remaining[(ear_index + 1) % remaining.length]
              triangles << [previous_point, current_point, following_point]
              remaining.delete_at(ear_index)
              projected.delete_at(ear_index)
              attempts += 1

              if attempts == 1 ||
                 (attempts % EAR_PROGRESS_INTERVAL).zero? ||
                 exact_ear_calls >= 100
                elapsed = LvnBridgeNearestFirstProbe.monotonic_time - started_at
                LvnBridgeNearestFirstProbe.log(
                  'QUALITY_FIRST_EAR_PROGRESS',
                  {
                    clipped_triangle_count: attempts,
                    remaining_vertex_count: remaining.length,
                    ordered_candidate_count: ordered_candidates.length,
                    exact_ear_calls: exact_ear_calls,
                    selected_polygon_index: ear_index,
                    selected_quality_numerator: selected_quality.numerator,
                    selected_quality_denominator: selected_quality.denominator,
                    total_exact_ear_calls: total_exact_ear_calls,
                    elapsed_s: elapsed
                  }
                )
              end

              if attempts > limit
                raise ReconstructionError,
                      'Exact coplanar patch triangulation exceeded its iteration limit'
              end
            end

            final = projected
            if final.uniq.length != 3 || integer_orientation_2d(*final).zero?
              raise ReconstructionError,
                    "Exact coplanar patch ended with a zero-area triangle: #{remaining.inspect}"
            end
            triangles << remaining

            duration = LvnBridgeNearestFirstProbe.monotonic_time - started_at
            LvnBridgeNearestFirstProbe.log(
              'QUALITY_FIRST_EAR_END',
              {
                initial_vertex_count: initial_vertex_count,
                triangle_count: triangles.length,
                clipped_triangle_count: attempts,
                total_ordered_candidates: total_ordered_candidates,
                total_exact_ear_calls: total_exact_ear_calls,
                max_exact_ear_calls: max_exact_ear_calls,
                duration_s: duration
              }
            )
            triangles
          rescue StandardError => error
            LvnBridgeNearestFirstProbe.log(
              'QUALITY_FIRST_EAR_ERROR',
              {
                initial_vertex_count: initial_vertex_count,
                remaining_vertex_count: remaining&.length,
                clipped_triangle_count: attempts,
                total_exact_ear_calls: total_exact_ear_calls,
                error_class: error.class.to_s,
                error_message: error.message.to_s,
                backtrace: Array(error.backtrace).first(8)
              },
              level: 'ERROR'
            )
            raise
          end
        end

        LocalVertexNormalizer.prepend(NearestFirstBridge) unless
          LocalVertexNormalizer.ancestors.include?(NearestFirstBridge)

        # Define the probe implementation on the class itself so existing
        # production prepend wrappers (debug profiler and conservative ear broad
        # phase) still wrap this method and retain their context/statistics.
        original_ear_owner =
          LocalVertexNormalizer.instance_method(
            :triangulate_exact_weak_polygon
          ).owner
        LocalVertexNormalizer.class_eval do
          define_method(
            :triangulate_exact_weak_polygon,
            QualityFirstEarTriangulation.instance_method(
              :triangulate_exact_weak_polygon
            )
          )
          private :triangulate_exact_weak_polygon
        end

        log(
          'QUALITY_FIRST_EAR_INSTALLED',
          {
            original_owner: original_ear_owner.to_s,
            replacement_owner:
              LocalVertexNormalizer.instance_method(
                :triangulate_exact_weak_polygon
              ).owner.to_s
          }
        )

        DETAIL.reset_progress
        BASE.run
      end
    end
  end
end
