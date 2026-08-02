# frozen_string_literal: true

# Dev-only probe. Replaces per-group full geometry_counts scans with local
# topology deltas, while checking the complete reference every 100 groups and
# at every pass boundary. Any mismatch raises, so the outer LVN operation rolls
# back. Production files are unchanged.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnCoplanarIncrementalTopologyProbe
        INTERVAL = 100
        KEYS = %i[
          faces edges vertices boundary_edges wire_edges overused_edges
          orientation_conflicts
        ].freeze
        EDGE_KEYS = (KEYS - [:faces]).freeze

        module Implementation
          private

          def remove_coplanar_shared_edges(
            entities,
            plane_tolerance_mm:,
            angle_tolerance_deg:
          )
            probe = LvnBridgeNearestFirstProbe
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            removed = removed_groups = unchanged = 0
            ignored = {}
            reports = []
            max_deviation = max_angle = 0.0
            multi_groups = max_group_edges = 0
            groups_done = references = 0
            last_reference = -1
            topology = geometry_counts(entities)
            full_calls = 1

            probe.log('COPLANAR_INCREMENTAL_BEGIN', {
              interval: LvnCoplanarIncrementalTopologyProbe::INTERVAL,
              topology: topology
            })

            MAX_COPLANAR_PASSES.times do |pass_index|
              groups = coplanar_shared_edge_groups(
                entities,
                plane_tolerance_mm: plane_tolerance_mm,
                angle_tolerance_deg: angle_tolerance_deg,
                ignored_group_signatures: ignored
              )
              break if groups.empty?

              pass_edges = pass_groups = 0
              groups.each do |group|
                current = refresh_coplanar_shared_edge_group(
                  group,
                  plane_tolerance_mm: plane_tolerance_mm,
                  angle_tolerance_deg: angle_tolerance_deg
                )
                next unless current

                edges = current[:edges]
                before_topology = topology.dup
                affected_before, seed_vertices =
                  incremental_coplanar_affected_before(current)
                local_before = incremental_coplanar_edge_counts(affected_before)
                face_context = incremental_coplanar_face_context(
                  current,
                  affected_before
                )

                begin
                  entities.erase_entities(edges)
                rescue ArgumentError => error
                  ignored[current[:signature]] = true
                  unchanged += edges.length
                  next if error.message.to_s.downcase.include?('not planar')
                  raise
                end

                affected_after = incremental_coplanar_affected_after(
                  affected_before,
                  seed_vertices
                )
                local_after = incremental_coplanar_edge_counts(affected_after)
                faces_after = incremental_coplanar_faces_after(
                  affected_after,
                  face_context[:outside]
                )
                reduction = face_context[:count] - faces_after
                expected = current[:self_adjacent] ? 0 : 1
                unless reduction == expected
                  raise DestructiveCoplanarCleanupError,
                        "Incremental coplanar face reduction mismatch: " \
                        "shared_edges=#{edges.length} self_adjacent=" \
                        "#{current[:self_adjacent]} local_faces=" \
                        "#{face_context[:count]}->#{faces_after}"
                end

                after_topology = incremental_coplanar_apply_delta(
                  before_topology,
                  local_before,
                  local_after,
                  reduction
                )
                if closed_surface?(before_topology) &&
                   !closed_surface?(after_topology)
                  raise DestructiveCoplanarCleanupError,
                        "Incremental coplanar cleanup opened shell: " \
                        "before=#{before_topology.inspect} " \
                        "after=#{after_topology.inspect}"
                end
                if topology_anomaly_score(after_topology) >
                   topology_anomaly_score(before_topology)
                  raise DestructiveCoplanarCleanupError,
                        "Incremental coplanar cleanup increased anomalies: " \
                        "before=#{before_topology.inspect} " \
                        "after=#{after_topology.inspect}"
                end
                if edges.any?(&:valid?)
                  raise DestructiveCoplanarCleanupError,
                        "Coplanar cleanup left shared edges valid: " \
                        "#{edges.count(&:valid?)}/#{edges.length}"
                end

                topology = after_topology
                edge_count = edges.length
                removed += edge_count
                removed_groups += 1
                pass_edges += edge_count
                pass_groups += 1
                groups_done += 1
                multi_groups += 1 if edge_count > 1
                max_group_edges = [max_group_edges, edge_count].max
                max_deviation = [
                  max_deviation,
                  current[:max_plane_deviation_mm]
                ].max
                max_angle = [max_angle, current[:max_angle_deg]].max

                next unless (groups_done %
                  LvnCoplanarIncrementalTopologyProbe::INTERVAL).zero?

                topology = incremental_coplanar_reference!(
                  entities,
                  topology,
                  probe,
                  pass_index + 1,
                  groups_done,
                  'interval'
                )
                full_calls += 1
                references += 1
                last_reference = groups_done
                probe.log('COPLANAR_INCREMENTAL_PROGRESS', {
                  pass: pass_index + 1,
                  groups: groups_done,
                  removed_edges: removed,
                  full_geometry_counts_calls: full_calls,
                  avoided_geometry_counts_calls: (groups_done * 2) - full_calls,
                  topology: topology,
                  elapsed_s: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
                })
              end

              break if pass_edges.zero?

              if last_reference != groups_done
                topology = incremental_coplanar_reference!(
                  entities,
                  topology,
                  probe,
                  pass_index + 1,
                  groups_done,
                  'pass_end'
                )
                full_calls += 1
                references += 1
                last_reference = groups_done
              end
              reports << {
                pass: pass_index + 1,
                removed_edges: pass_edges,
                removed_groups: pass_groups
              }
            end

            remaining = coplanar_shared_edge_groups(
              entities,
              plane_tolerance_mm: plane_tolerance_mm,
              angle_tolerance_deg: angle_tolerance_deg,
              ignored_group_signatures: ignored
            )
            unless remaining.empty?
              sample = remaining.first(10).map do |group|
                [group[:key], group[:edges].length]
              end
              raise DestructiveCoplanarCleanupError,
                    "Coplanar cleanup did not converge: " \
                    "remaining=#{remaining.length} sample=#{sample.inspect}"
            end

            all_remaining = coplanar_shared_edge_groups(
              entities,
              plane_tolerance_mm: plane_tolerance_mm,
              angle_tolerance_deg: angle_tolerance_deg
            )
            ignored_remaining = all_remaining.count do |group|
              ignored[group[:signature]]
            end

            probe.log('COPLANAR_INCREMENTAL_END', {
              groups: groups_done,
              removed_edges: removed,
              references: references,
              full_geometry_counts_calls: full_calls,
              production_geometry_counts_calls: groups_done * 2,
              avoided_geometry_counts_calls: (groups_done * 2) - full_calls,
              topology: topology,
              elapsed_s: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            })

            {
              removed_edges: removed,
              removed_groups: removed_groups,
              unchanged_edges: unchanged,
              ignored_groups: ignored_remaining,
              passes: reports,
              max_plane_deviation_mm: max_deviation,
              max_angle_deg: max_angle,
              multi_edge_group_count: multi_groups,
              max_shared_edges_per_group: max_group_edges,
              fallback_reason: nil
            }
          rescue StandardError => error
            probe&.log('COPLANAR_INCREMENTAL_ERROR', {
              error_class: error.class.to_s,
              error_message: error.message,
              groups: groups_done,
              removed_edges: removed,
              references: references,
              full_geometry_counts_calls: full_calls,
              topology: topology,
              elapsed_s: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            }, level: 'ERROR')
            raise
          end

          def incremental_coplanar_affected_before(current)
            face_edges = Array(current[:faces]).flat_map do |face|
              face&.valid? ? Array(face.edges) : []
            rescue StandardError
              []
            end
            seed_edges = incremental_coplanar_unique(
              face_edges + Array(current[:edges])
            )
            vertices = seed_edges.flat_map do |edge|
              Array(edge.vertices)
            rescue StandardError
              []
            end.uniq
            [
              incremental_coplanar_unique(
                seed_edges + incremental_coplanar_incident(vertices)
              ),
              vertices
            ]
          end

          def incremental_coplanar_affected_after(before, vertices)
            survivors = Array(before).select do |edge|
              edge&.valid?
            rescue StandardError
              false
            end
            incremental_coplanar_unique(
              survivors + incremental_coplanar_incident(vertices)
            )
          end

          def incremental_coplanar_incident(vertices)
            Array(vertices).flat_map do |vertex|
              vertex.respond_to?(:edges) ? Array(vertex.edges) : []
            rescue StandardError
              []
            end
          end

          def incremental_coplanar_unique(items)
            seen = {}
            Array(items).each_with_object([]) do |item, result|
              next unless item&.valid?
              key = [item.class.name, stable_entity_id(item)]
              next if seen[key]
              seen[key] = true
              result << item
            rescue StandardError
              next
            end
          end

          def incremental_coplanar_face_context(current, affected)
            local = incremental_coplanar_unique(Array(current[:faces]))
            local_ids = local.to_h { |face| [stable_entity_id(face), true] }
            outside = {}
            Array(affected).each do |edge|
              Array(edge.faces).each do |face|
                next unless face&.valid?
                id = stable_entity_id(face)
                outside[id] = true unless local_ids[id]
              end
            rescue StandardError
              next
            end
            { count: local.length, outside: outside }
          end

          def incremental_coplanar_faces_after(affected, outside)
            faces = Array(affected).flat_map do |edge|
              Array(edge.faces)
            rescue StandardError
              []
            end
            incremental_coplanar_unique(faces).count do |face|
              !outside[stable_entity_id(face)]
            end
          end

          def incremental_coplanar_edge_counts(items)
            edges = incremental_coplanar_unique(items)
            result = {
              edges: edges.length,
              vertices: edges.flat_map do |edge|
                Array(edge.vertices)
              rescue StandardError
                []
              end.uniq.length,
              boundary_edges: 0,
              wire_edges: 0,
              overused_edges: 0,
              orientation_conflicts: 0
            }
            edges.each do |edge|
              faces = Array(edge.faces)
              case faces.length
              when 0 then result[:wire_edges] += 1
              when 1 then result[:boundary_edges] += 1
              when 2
                begin
                  result[:orientation_conflicts] += 1 if
                    edge.reversed_in?(faces[0]) == edge.reversed_in?(faces[1])
                rescue StandardError
                  nil
                end
              else result[:overused_edges] += 1
              end
            rescue StandardError
              next
            end
            result
          end

          def incremental_coplanar_apply_delta(before, local_before, local_after, reduction)
            after = before.dup
            after[:faces] = before[:faces].to_i - reduction
            LvnCoplanarIncrementalTopologyProbe::EDGE_KEYS.each do |key|
              after[key] = before[key].to_i + local_after[key].to_i - local_before[key].to_i
            end
            negative = LvnCoplanarIncrementalTopologyProbe::KEYS.select do |key|
              after[key].to_i.negative?
            end
            unless negative.empty?
              raise DestructiveCoplanarCleanupError,
                    "Incremental topology became negative: " \
                    "#{negative.inspect} #{after.inspect}"
            end
            after
          end

          def incremental_coplanar_reference!(entities, predicted, probe, pass, groups, reason)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            actual = geometry_counts(entities)
            mismatch = {}
            LvnCoplanarIncrementalTopologyProbe::KEYS.each do |key|
              next if predicted[key].to_i == actual[key].to_i
              mismatch[key] = [predicted[key], actual[key]]
            end
            event = mismatch.empty? ?
              'COPLANAR_INCREMENTAL_REFERENCE_MATCH' :
              'COPLANAR_INCREMENTAL_REFERENCE_MISMATCH'
            probe.log(event, {
              pass: pass,
              groups: groups,
              reason: reason,
              mismatch: mismatch,
              predicted: predicted,
              actual: actual,
              duration_s: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            }, level: mismatch.empty? ? 'INFO' : 'ERROR')
            unless mismatch.empty?
              raise DestructiveCoplanarCleanupError,
                    "Incremental topology differs from full reference: " \
                    "#{mismatch.inspect}"
            end
            actual
          end
        end
      end
    end
  end
end

normalizer = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
implementation = ULOL::Indoor3DGmlModeler::IndoorCore::
  LvnCoplanarIncrementalTopologyProbe::Implementation
methods = implementation.private_instance_methods(false)
required = %i[
  remove_coplanar_shared_edges incremental_coplanar_affected_before
  incremental_coplanar_affected_after incremental_coplanar_incident
  incremental_coplanar_unique incremental_coplanar_face_context
  incremental_coplanar_faces_after incremental_coplanar_edge_counts
  incremental_coplanar_apply_delta incremental_coplanar_reference!
]
missing = required - methods
raise "Incremental coplanar methods missing: #{missing.inspect}" unless missing.empty?

normalizer.class_eval do
  methods.each do |name|
    define_method(name, implementation.instance_method(name))
    private name
  end
end

load File.join(__dir__, 'lvn_bridge_blocked_ear_recovery_probe.rb')
