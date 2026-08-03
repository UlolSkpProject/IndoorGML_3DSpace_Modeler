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
        EAR_REFERENCE_INTERVAL = 250
        EAR_REFERENCE_FULL_CHECK_MAX_VERTICES = 64

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

        # Exact-equivalent incremental ear selection for the dev probe.
        #
        # Production chooses the valid ear with maximum exact quality on every
        # iteration. Removing one ear changes local quality/convexity only for its
        # two surviving neighbours. Keep every other candidate in a max-heap,
        # refresh those two neighbours, and lazily run the unchanged exact ear
        # predicate in the same [quality descending, polygon index ascending]
        # order. Rejected candidates are reinserted because later clipping may
        # make a previously invalid ear valid.
        module IncrementalEarTriangulation
          private

          def triangulate_exact_weak_polygon(points, drop_axis)
            started_at = LvnBridgeNearestFirstProbe.monotonic_time
            remaining = points.dup
            projected = remaining.map do |point|
              integer_project_2d(point, drop_axis)
            end
            remaining_ids = Array.new(remaining.length) { |index| index }
            index_by_id = remaining_ids.each_with_index.to_h
            versions = Array.new(remaining.length, 0)
            heap = []
            triangles = []
            limit = remaining.length * remaining.length * 2
            attempts = 0
            initial_vertex_count = remaining.length

            stats = {
              quality_evaluations: 0,
              heap_pops: 0,
              stale_heap_pops: 0,
              exact_ear_calls: 0,
              rejected_reinsertions: 0,
              local_candidate_refreshes: 0,
              reference_checks: 0,
              reference_quality_evaluations: 0,
              reference_exact_ear_calls: 0,
              max_exact_ear_calls: 0,
              max_heap_size: 0
            }

            remaining_ids.each do |vertex_id|
              incremental_ear_refresh_candidate!(
                heap,
                remaining,
                projected,
                index_by_id,
                versions,
                vertex_id,
                drop_axis,
                stats
              )
            end
            stats[:max_heap_size] = heap.length

            LvnBridgeNearestFirstProbe.log(
              'INCREMENTAL_EAR_BEGIN',
              {
                initial_vertex_count: initial_vertex_count,
                initial_candidate_count: heap.length,
                drop_axis: drop_axis,
                reference_interval: EAR_REFERENCE_INTERVAL,
                full_reference_check_max_vertices:
                  EAR_REFERENCE_FULL_CHECK_MAX_VERTICES
              }
            )

            while remaining.length > 3
              reference = nil
              if incremental_ear_reference_due?(
                attempts,
                initial_vertex_count
              )
                reference = incremental_ear_reference_selection(
                  remaining,
                  projected,
                  remaining_ids,
                  drop_axis
                )
                stats[:reference_checks] += 1
                stats[:reference_quality_evaluations] +=
                  reference[:candidate_count]
                stats[:reference_exact_ear_calls] +=
                  reference[:exact_ear_calls]
              end

              rejected = []
              selected = nil
              exact_ear_calls = 0

              until heap.empty?
                entry = incremental_ear_heap_pop!(heap)
                stats[:heap_pops] += 1
                quality, vertex_id, version = entry
                index = index_by_id[vertex_id]

                unless index && versions[vertex_id] == version
                  stats[:stale_heap_pops] += 1
                  next
                end

                previous_index = (index - 1) % remaining.length
                following_index = (index + 1) % remaining.length
                unless integer_orientation_2d(
                  projected[previous_index],
                  projected[index],
                  projected[following_index]
                ).positive?
                  stats[:stale_heap_pops] += 1
                  next
                end

                exact_ear_calls += 1
                stats[:exact_ear_calls] += 1
                if exact_polygon_ear?(
                  remaining,
                  index,
                  drop_axis,
                  projected: projected
                )
                  selected = [quality, vertex_id, version, index]
                  break
                end

                rejected << entry
              end

              rejected.each do |entry|
                incremental_ear_heap_push!(heap, entry)
              end
              stats[:rejected_reinsertions] += rejected.length

              unless selected
                raise ReconstructionError,
                      "Could not triangulate exact coplanar patch boundary: " \
                      "#{remaining.inspect}"
              end

              selected_quality, selected_id, _version, ear_index = selected
              stats[:max_exact_ear_calls] = [
                stats[:max_exact_ear_calls],
                exact_ear_calls
              ].max

              if reference
                reference_id = reference[:vertex_id]
                unless reference_id == selected_id &&
                       reference[:quality] == selected_quality
                  raise ReconstructionError,
                        'Incremental exact ear selection diverged from full reference: ' \
                        "incremental_id=#{selected_id} " \
                        "reference_id=#{reference_id} " \
                        "incremental_quality=#{selected_quality} " \
                        "reference_quality=#{reference[:quality]}"
                end

                LvnBridgeNearestFirstProbe.log(
                  'INCREMENTAL_EAR_REFERENCE_MATCH',
                  {
                    clipped_triangle_count: attempts,
                    remaining_vertex_count: remaining.length,
                    selected_vertex_id: selected_id,
                    selected_polygon_index: ear_index,
                    selected_quality_numerator: selected_quality.numerator,
                    selected_quality_denominator: selected_quality.denominator,
                    reference_candidate_count: reference[:candidate_count],
                    reference_exact_ear_calls: reference[:exact_ear_calls]
                  }
                )
              end

              previous_index = (ear_index - 1) % remaining.length
              following_index = (ear_index + 1) % remaining.length
              previous_id = remaining_ids[previous_index]
              following_id = remaining_ids[following_index]

              triangles << [
                remaining[previous_index],
                remaining[ear_index],
                remaining[following_index]
              ]

              remaining.delete_at(ear_index)
              projected.delete_at(ear_index)
              remaining_ids.delete_at(ear_index)
              index_by_id.delete(selected_id)
              versions[selected_id] += 1
              (ear_index...remaining_ids.length).each do |index|
                index_by_id[remaining_ids[index]] = index
              end

              if remaining.length > 3
                [previous_id, following_id].uniq.each do |vertex_id|
                  versions[vertex_id] += 1
                  incremental_ear_refresh_candidate!(
                    heap,
                    remaining,
                    projected,
                    index_by_id,
                    versions,
                    vertex_id,
                    drop_axis,
                    stats
                  )
                  stats[:local_candidate_refreshes] += 1
                end
                stats[:max_heap_size] = [
                  stats[:max_heap_size],
                  heap.length
                ].max
              end

              attempts += 1
              if attempts == 1 ||
                 (attempts % EAR_PROGRESS_INTERVAL).zero?
                elapsed = LvnBridgeNearestFirstProbe.monotonic_time - started_at
                LvnBridgeNearestFirstProbe.log(
                  'INCREMENTAL_EAR_PROGRESS',
                  {
                    clipped_triangle_count: attempts,
                    remaining_vertex_count: remaining.length,
                    heap_size: heap.length,
                    exact_ear_calls: exact_ear_calls,
                    selected_vertex_id: selected_id,
                    selected_polygon_index: ear_index,
                    selected_quality_numerator: selected_quality.numerator,
                    selected_quality_denominator: selected_quality.denominator,
                    quality_evaluations: stats[:quality_evaluations],
                    total_exact_ear_calls: stats[:exact_ear_calls],
                    heap_pops: stats[:heap_pops],
                    stale_heap_pops: stats[:stale_heap_pops],
                    rejected_reinsertions: stats[:rejected_reinsertions],
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
              'INCREMENTAL_EAR_END',
              {
                initial_vertex_count: initial_vertex_count,
                triangle_count: triangles.length,
                clipped_triangle_count: attempts,
                duration_s: duration
              }.merge(stats)
            )
            triangles
          rescue StandardError => error
            LvnBridgeNearestFirstProbe.log(
              'INCREMENTAL_EAR_ERROR',
              {
                initial_vertex_count: initial_vertex_count,
                remaining_vertex_count: remaining&.length,
                clipped_triangle_count: attempts,
                heap_size: heap&.length,
                stats: stats,
                error_class: error.class.to_s,
                error_message: error.message.to_s,
                backtrace: Array(error.backtrace).first(8)
              },
              level: 'ERROR'
            )
            raise
          end

          def incremental_ear_reference_due?(attempts, initial_vertex_count)
            return true if initial_vertex_count <=
                           EAR_REFERENCE_FULL_CHECK_MAX_VERTICES
            return true if attempts.zero?

            (attempts % EAR_REFERENCE_INTERVAL).zero?
          end

          def incremental_ear_reference_selection(
            remaining,
            projected,
            remaining_ids,
            drop_axis
          )
            candidates = remaining.each_index.filter_map do |index|
              previous_index = (index - 1) % remaining.length
              following_index = (index + 1) % remaining.length
              next unless integer_orientation_2d(
                projected[previous_index],
                projected[index],
                projected[following_index]
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
            selected = candidates.find do |_quality, index|
              exact_ear_calls += 1
              exact_polygon_ear?(
                remaining,
                index,
                drop_axis,
                projected: projected
              )
            end

            unless selected
              return {
                quality: nil,
                vertex_id: nil,
                polygon_index: nil,
                candidate_count: candidates.length,
                exact_ear_calls: exact_ear_calls
              }
            end

            quality, index = selected
            {
              quality: quality,
              vertex_id: remaining_ids[index],
              polygon_index: index,
              candidate_count: candidates.length,
              exact_ear_calls: exact_ear_calls
            }
          end

          def incremental_ear_refresh_candidate!(
            heap,
            remaining,
            projected,
            index_by_id,
            versions,
            vertex_id,
            drop_axis,
            stats
          )
            index = index_by_id[vertex_id]
            return unless index

            previous_index = (index - 1) % remaining.length
            following_index = (index + 1) % remaining.length
            return unless integer_orientation_2d(
              projected[previous_index],
              projected[index],
              projected[following_index]
            ).positive?

            quality = exact_polygon_ear_quality(
              remaining,
              index,
              drop_axis,
              projected: projected
            )
            stats[:quality_evaluations] += 1
            incremental_ear_heap_push!(
              heap,
              [quality, vertex_id, versions[vertex_id]]
            )
          end

          def incremental_ear_heap_higher_priority?(first, second)
            quality_comparison = first[0] <=> second[0]
            return true if quality_comparison.positive?
            return false if quality_comparison.negative?

            first[1] < second[1]
          end

          def incremental_ear_heap_push!(heap, entry)
            heap << entry
            child = heap.length - 1
            while child.positive?
              parent = (child - 1) / 2
              break unless incremental_ear_heap_higher_priority?(
                heap[child],
                heap[parent]
              )

              heap[child], heap[parent] = heap[parent], heap[child]
              child = parent
            end
            heap
          end

          def incremental_ear_heap_pop!(heap)
            top = heap.first
            tail = heap.pop
            return top if heap.empty?

            heap[0] = tail
            parent = 0
            loop do
              left = (parent * 2) + 1
              break if left >= heap.length

              right = left + 1
              child = if right < heap.length &&
                         incremental_ear_heap_higher_priority?(
                           heap[right],
                           heap[left]
                         )
                        right
                      else
                        left
                      end
              break unless incremental_ear_heap_higher_priority?(
                heap[child],
                heap[parent]
              )

              heap[parent], heap[child] = heap[child], heap[parent]
              parent = child
            end
            top
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
            IncrementalEarTriangulation.instance_method(
              :triangulate_exact_weak_polygon
            )
          )
          private :triangulate_exact_weak_polygon
        end

        log(
          'INCREMENTAL_EAR_INSTALLED',
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
