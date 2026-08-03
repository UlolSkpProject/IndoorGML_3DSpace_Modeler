# frozen_string_literal: true

# Development-only launcher for blocker-aware incremental ear clipping.
#
# It keeps the established nearest-first hole bridge, heap quality ordering,
# exact broad phase, and exact predicates. An invalid ear is suspended behind
# the exact vertex/edge that rejected it and is reactivated only when that
# blocker disappears. Production files are not modified.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnBridgeBlockedEarProbe
        module BlockedEarTriangulation
          private

          def triangulate_exact_weak_polygon(points, drop_axis)
            probe = LvnBridgeNearestFirstProbe
            started_at = probe.monotonic_time
            remaining = points.dup
            projected = remaining.map do |point|
              integer_project_2d(point, drop_axis)
            end
            remaining_ids = Array.new(remaining.length) { |index| index }
            index_by_id = remaining_ids.each_with_index.to_h
            versions = Array.new(remaining.length, 0)
            heap = []
            blocked_entries = {}
            blocked_by_vertex = Hash.new { |hash, key| hash[key] = {} }
            blocked_by_edge = Hash.new { |hash, key| hash[key] = {} }
            triangles = []
            limit = remaining.length * remaining.length * 2
            attempts = 0
            initial_vertex_count = remaining.length

            stats = {
              quality_evaluations: 0,
              heap_pops: 0,
              stale_heap_pops: 0,
              exact_ear_calls: 0,
              blocked_suspensions: 0,
              vertex_blocked_suspensions: 0,
              edge_blocked_suspensions: 0,
              blocker_releases: 0,
              blocker_reactivations: 0,
              fallback_reinsertions: 0,
              local_candidate_refreshes: 0,
              reference_checks: 0,
              reference_quality_evaluations: 0,
              reference_exact_ear_calls: 0,
              max_exact_ear_calls: 0,
              max_heap_size: 0,
              max_blocked_entries: 0
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

            probe.log(
              'BLOCKED_EAR_BEGIN',
              {
                initial_vertex_count: initial_vertex_count,
                initial_candidate_count: heap.length,
                drop_axis: drop_axis,
                reference_interval:
                  LvnBridgeNearestFirstProbe::EAR_REFERENCE_INTERVAL,
                full_reference_check_max_vertices:
                  LvnBridgeNearestFirstProbe::
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

              selected = nil
              fallback_rejected = []
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
                valid, blocker_kind, blocker_key =
                  blocked_exact_polygon_ear_v3(
                    remaining,
                    projected,
                    remaining_ids,
                    index,
                    drop_axis
                  )
                if valid
                  selected = [quality, vertex_id, version, index]
                  break
                end

                if blocker_kind && blocker_key
                  blocked_ear_register_v3!(
                    blocked_entries,
                    blocked_by_vertex,
                    blocked_by_edge,
                    vertex_id,
                    entry,
                    blocker_kind,
                    blocker_key,
                    stats
                  )
                else
                  # A conservative fallback preserves the old behavior whenever
                  # the exact broad-phase context cannot expose a stable blocker.
                  fallback_rejected << entry
                end
              end

              fallback_rejected.each do |entry|
                incremental_ear_heap_push!(heap, entry)
              end
              stats[:fallback_reinsertions] += fallback_rejected.length

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
                        'Blocker-aware exact ear selection diverged from full reference: ' \
                        "blocked_id=#{selected_id} " \
                        "reference_id=#{reference_id} " \
                        "blocked_quality=#{selected_quality} " \
                        "reference_quality=#{reference[:quality]}"
                end

                probe.log(
                  'BLOCKED_EAR_REFERENCE_MATCH',
                  {
                    clipped_triangle_count: attempts,
                    remaining_vertex_count: remaining.length,
                    selected_vertex_id: selected_id,
                    selected_polygon_index: ear_index,
                    selected_quality_numerator: selected_quality.numerator,
                    selected_quality_denominator: selected_quality.denominator,
                    reference_candidate_count: reference[:candidate_count],
                    reference_exact_ear_calls: reference[:exact_ear_calls],
                    blocked_entry_count: blocked_entries.length
                  }
                )
              end

              previous_index = (ear_index - 1) % remaining.length
              following_index = (ear_index + 1) % remaining.length
              previous_id = remaining_ids[previous_index]
              following_id = remaining_ids[following_index]
              removed_edges = [
                blocked_ear_edge_key_v3(previous_id, selected_id),
                blocked_ear_edge_key_v3(selected_id, following_id)
              ]

              triangles << [
                remaining[previous_index],
                remaining[ear_index],
                remaining[following_index]
              ]

              blocked_ear_forget_candidate_v3!(
                blocked_entries,
                blocked_by_vertex,
                blocked_by_edge,
                selected_id
              )
              released_entries = []
              blocked_ear_release_vertex_v3!(
                blocked_entries,
                blocked_by_vertex,
                blocked_by_edge,
                selected_id,
                released_entries,
                stats
              )
              removed_edges.each do |edge_key|
                blocked_ear_release_edge_v3!(
                  blocked_entries,
                  blocked_by_vertex,
                  blocked_by_edge,
                  edge_key,
                  released_entries,
                  stats
                )
              end

              remaining.delete_at(ear_index)
              projected.delete_at(ear_index)
              remaining_ids.delete_at(ear_index)
              index_by_id.delete(selected_id)
              versions[selected_id] += 1
              (ear_index...remaining_ids.length).each do |remaining_index|
                index_by_id[remaining_ids[remaining_index]] = remaining_index
              end

              [previous_id, following_id].uniq.each do |vertex_id|
                blocked_ear_forget_candidate_v3!(
                  blocked_entries,
                  blocked_by_vertex,
                  blocked_by_edge,
                  vertex_id
                )
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

                released_entries.each do |entry|
                  _quality, vertex_id, version = entry
                  next unless index_by_id[vertex_id]
                  next unless versions[vertex_id] == version

                  incremental_ear_heap_push!(heap, entry)
                  stats[:blocker_reactivations] += 1
                end
                stats[:max_heap_size] = [
                  stats[:max_heap_size],
                  heap.length
                ].max
              end

              attempts += 1
              if attempts == 1 ||
                 (attempts % LvnBridgeNearestFirstProbe::
                   EAR_PROGRESS_INTERVAL).zero?
                elapsed = probe.monotonic_time - started_at
                probe.log(
                  'BLOCKED_EAR_PROGRESS',
                  {
                    clipped_triangle_count: attempts,
                    remaining_vertex_count: remaining.length,
                    heap_size: heap.length,
                    blocked_entry_count: blocked_entries.length,
                    exact_ear_calls: exact_ear_calls,
                    selected_vertex_id: selected_id,
                    selected_polygon_index: ear_index,
                    selected_quality_numerator: selected_quality.numerator,
                    selected_quality_denominator: selected_quality.denominator,
                    quality_evaluations: stats[:quality_evaluations],
                    total_exact_ear_calls: stats[:exact_ear_calls],
                    blocked_suspensions: stats[:blocked_suspensions],
                    blocker_releases: stats[:blocker_releases],
                    blocker_reactivations: stats[:blocker_reactivations],
                    fallback_reinsertions: stats[:fallback_reinsertions],
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

            duration = probe.monotonic_time - started_at
            probe.log(
              'BLOCKED_EAR_END',
              {
                initial_vertex_count: initial_vertex_count,
                triangle_count: triangles.length,
                clipped_triangle_count: attempts,
                duration_s: duration
              }.merge(stats)
            )
            triangles
          rescue StandardError => error
            probe&.log(
              'BLOCKED_EAR_ERROR',
              {
                initial_vertex_count: initial_vertex_count,
                remaining_vertex_count: remaining&.length,
                clipped_triangle_count: attempts,
                heap_size: heap&.length,
                blocked_entry_count: blocked_entries&.length,
                stats: stats,
                error_class: error.class.to_s,
                error_message: error.message.to_s,
                backtrace: Array(error.backtrace).first(10)
              },
              level: 'ERROR'
            )
            raise
          end

          def blocked_exact_polygon_ear_v3(
            polygon,
            projected,
            vertex_ids,
            index,
            drop_axis
          )
            broad_phase_module =
              LocalVertexNormalizerExactPolygonEarBroadPhaseV2
            threshold = broad_phase_module::
              EXACT_POLYGON_EAR_BROAD_PHASE_THRESHOLD
            stats = @local_vertex_normalizer_exact_ear_broad_phase_stats_v2
            context = @local_vertex_normalizer_exact_ear_broad_phase_context_v2
            unless stats && context && projected && polygon.length >= threshold
              return [
                exact_polygon_ear?(
                  polygon,
                  index,
                  drop_axis,
                  projected: projected
                ),
                nil,
                nil
              ]
            end

            stats[:ear_calls] += 1
            broad_phase = exact_polygon_ear_broad_phase_index_v2(
              projected,
              context,
              stats
            )
            unless broad_phase
              return [
                exact_polygon_ear?(
                  polygon,
                  index,
                  drop_axis,
                  projected: projected
                ),
                nil,
                nil
              ]
            end

            previous_index = (index - 1) % polygon.length
            following_index = (index + 1) % polygon.length
            point_a = projected[previous_index]
            point_b = projected[index]
            point_c = projected[following_index]
            return [false, nil, nil] unless integer_orientation_2d(
              point_a,
              point_b,
              point_c
            ).positive?

            triangle_bounds = exact_polygon_ear_bounds_2d_v2(
              [point_a, point_b, point_c]
            )
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
              next if candidate == point_a ||
                      candidate == point_b ||
                      candidate == point_c

              stats[:exact_point_tests] += 1
              if integer_point_in_triangle_2d?(
                candidate,
                point_a,
                point_b,
                point_c
              )
                return [false, :vertex, vertex_ids[candidate_index]]
              end
            end

            diagonal_bounds = exact_polygon_ear_bounds_2d_v2(
              [point_a, point_c]
            )
            edge_indices = exact_polygon_ear_edge_candidates_v2(
              broad_phase,
              diagonal_bounds,
              stats
            )
            edge_indices.each do |edge_index|
              edge_following = (edge_index + 1) % polygon.length
              next if edge_index == previous_index || edge_index == index
              next if edge_following == previous_index ||
                      edge_following == following_index

              edge_a = projected[edge_index]
              edge_b = projected[edge_following]
              next if edge_a == point_a || edge_b == point_a ||
                      edge_a == point_c || edge_b == point_c

              stats[:exact_segment_tests] += 1
              if integer_segments_intersect_2d?(
                point_a,
                point_c,
                edge_a,
                edge_b
              )
                edge_key = blocked_ear_edge_key_v3(
                  vertex_ids[edge_index],
                  vertex_ids[edge_following]
                )
                return [false, :edge, edge_key]
              end
            end

            [true, nil, nil]
          rescue StandardError => error
            exact_polygon_ear_broad_phase_fallback_v2(stats, error) if stats
            [
              exact_polygon_ear?(
                polygon,
                index,
                drop_axis,
                projected: projected
              ),
              nil,
              nil
            ]
          end

          def blocked_ear_register_v3!(
            blocked_entries,
            blocked_by_vertex,
            blocked_by_edge,
            candidate_id,
            entry,
            blocker_kind,
            blocker_key,
            stats
          )
            blocked_ear_forget_candidate_v3!(
              blocked_entries,
              blocked_by_vertex,
              blocked_by_edge,
              candidate_id
            )
            record = {
              entry: entry,
              blocker_kind: blocker_kind,
              blocker_key: blocker_key
            }
            blocked_entries[candidate_id] = record
            target = blocker_kind == :vertex ?
              blocked_by_vertex[blocker_key] :
              blocked_by_edge[blocker_key]
            target[candidate_id] = true
            stats[:blocked_suspensions] += 1
            if blocker_kind == :vertex
              stats[:vertex_blocked_suspensions] += 1
            else
              stats[:edge_blocked_suspensions] += 1
            end
            stats[:max_blocked_entries] = [
              stats[:max_blocked_entries],
              blocked_entries.length
            ].max
          end

          def blocked_ear_forget_candidate_v3!(
            blocked_entries,
            blocked_by_vertex,
            blocked_by_edge,
            candidate_id
          )
            record = blocked_entries.delete(candidate_id)
            return unless record

            registry = record[:blocker_kind] == :vertex ?
              blocked_by_vertex :
              blocked_by_edge
            dependents = registry[record[:blocker_key]]
            dependents.delete(candidate_id)
            registry.delete(record[:blocker_key]) if dependents.empty?
          end

          def blocked_ear_release_vertex_v3!(
            blocked_entries,
            blocked_by_vertex,
            blocked_by_edge,
            blocker_vertex_id,
            released_entries,
            stats
          )
            blocked_ear_release_registry_key_v3!(
              blocked_entries,
              blocked_by_vertex,
              blocked_by_edge,
              :vertex,
              blocker_vertex_id,
              released_entries,
              stats
            )
          end

          def blocked_ear_release_edge_v3!(
            blocked_entries,
            blocked_by_vertex,
            blocked_by_edge,
            blocker_edge_key,
            released_entries,
            stats
          )
            blocked_ear_release_registry_key_v3!(
              blocked_entries,
              blocked_by_vertex,
              blocked_by_edge,
              :edge,
              blocker_edge_key,
              released_entries,
              stats
            )
          end

          def blocked_ear_release_registry_key_v3!(
            blocked_entries,
            blocked_by_vertex,
            blocked_by_edge,
            blocker_kind,
            blocker_key,
            released_entries,
            stats
          )
            registry = blocker_kind == :vertex ?
              blocked_by_vertex :
              blocked_by_edge
            candidate_ids = registry.delete(blocker_key)&.keys || []
            stats[:blocker_releases] += 1 unless candidate_ids.empty?
            candidate_ids.each do |candidate_id|
              record = blocked_entries[candidate_id]
              next unless record
              next unless record[:blocker_kind] == blocker_kind &&
                          record[:blocker_key] == blocker_key

              blocked_entries.delete(candidate_id)
              released_entries << record[:entry]
            end
          end

          def blocked_ear_edge_key_v3(first_id, second_id)
            first_id <= second_id ?
              [first_id, second_id] :
              [second_id, first_id]
          end
        end
      end
    end
  end
end

probe_path = File.join(__dir__, 'lvn_bridge_nearest_first_probe.rb')
source = File.binread(probe_path)
             .force_encoding(Encoding::UTF_8)
             .gsub(/\r\n?/, "\n")

install_pattern = /\n        LocalVertexNormalizer\.class_eval do\n.*?\n        end\n\n        log\(\n          'INCREMENTAL_EAR_INSTALLED',/m

new_install = <<-'RUBY'
        incremental_method_names =
          IncrementalEarTriangulation.private_instance_methods(false)
        blocked_ear_module =
          LvnBridgeBlockedEarProbe::BlockedEarTriangulation
        blocked_method_names =
          blocked_ear_module.private_instance_methods(false)

        required_incremental_method_names = [
          :incremental_ear_reference_due?,
          :incremental_ear_reference_selection,
          :incremental_ear_refresh_candidate!,
          :incremental_ear_heap_higher_priority?,
          :incremental_ear_heap_push!,
          :incremental_ear_heap_pop!
        ]
        missing_incremental_method_names =
          required_incremental_method_names - incremental_method_names
        unless missing_incremental_method_names.empty?
          raise "Incremental ear probe helper methods missing: " \
                "#{missing_incremental_method_names.inspect}"
        end

        required_blocked_method_names = [
          :triangulate_exact_weak_polygon,
          :blocked_exact_polygon_ear_v3,
          :blocked_ear_register_v3!,
          :blocked_ear_forget_candidate_v3!,
          :blocked_ear_release_vertex_v3!,
          :blocked_ear_release_edge_v3!,
          :blocked_ear_release_registry_key_v3!,
          :blocked_ear_edge_key_v3
        ]
        missing_blocked_method_names =
          required_blocked_method_names - blocked_method_names
        unless missing_blocked_method_names.empty?
          raise "Blocked ear probe helper methods missing: " \
                "#{missing_blocked_method_names.inspect}"
        end

        LocalVertexNormalizer.class_eval do
          incremental_method_names.each do |method_name|
            define_method(
              method_name,
              IncrementalEarTriangulation.instance_method(method_name)
            )
            private method_name
          end
          blocked_method_names.each do |method_name|
            define_method(
              method_name,
              blocked_ear_module.instance_method(method_name)
            )
            private method_name
          end
        end

        log(
          'BLOCKED_EAR_INSTALLED',
          {
            replacement_owner:
              LocalVertexNormalizer.instance_method(
                :triangulate_exact_weak_polygon
              ).owner.to_s,
            exact_broad_phase_owner:
              LocalVertexNormalizer.instance_method(
                :exact_polygon_ear_broad_phase_index_v2
              ).owner.to_s
          }
        )
RUBY

replacement = "\n#{new_install}\n\n        log(\n          'INCREMENTAL_EAR_INSTALLED',"
patched = source.sub(install_pattern, replacement)
if patched == source
  raise "Could not replace incremental ear installation block in #{probe_path}"
end

RubyVM::InstructionSequence.compile(patched, probe_path)
TOPLEVEL_BINDING.eval(patched, probe_path, 1)
