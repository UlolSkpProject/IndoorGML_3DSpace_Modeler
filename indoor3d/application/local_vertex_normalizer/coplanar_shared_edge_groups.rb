# frozen_string_literal: true

require_relative 'coplanar_collinear_edge_policy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        COPLANAR_INCREMENTAL_REFERENCE_INTERVAL = 100 unless const_defined?(
          :COPLANAR_INCREMENTAL_REFERENCE_INTERVAL,
          false
        )
        COPLANAR_INCREMENTAL_TOPOLOGY_KEYS = %i[
          faces edges vertices boundary_edges wire_edges overused_edges
          orientation_conflicts
        ].freeze unless const_defined?(:COPLANAR_INCREMENTAL_TOPOLOGY_KEYS, false)
        COPLANAR_INCREMENTAL_EDGE_KEYS = (
          COPLANAR_INCREMENTAL_TOPOLOGY_KEYS - [:faces]
        ).freeze unless const_defined?(:COPLANAR_INCREMENTAL_EDGE_KEYS, false)

        private

        # Coplanarity is a property of the complete face pair, not of one
        # particular shared edge. Keep the pair-level calculation separate so a
        # boundary split into several SketchUp edges is evaluated once and then
        # removed as one atomic group.
        def coplanar_face_pair_metrics(
          face_a,
          face_b,
          plane_tolerance_mm:,
          angle_tolerance_deg:
        )
          return nil unless face_a&.valid? && face_b&.valid?

          normal_a = vector_components(face_a.normal)
          normal_b = vector_components(face_b.normal)
          length_product = vector_length(normal_a) * vector_length(normal_b)
          return nil unless length_product.positive?

          cosine = vector_dot(normal_a, normal_b) / length_product
          return nil unless cosine.positive?

          clamped_cosine = [[cosine, -1.0].max, 1.0].min
          angle_deg = Math.acos(clamped_cosine) * 180.0 / Math::PI
          return nil if angle_deg > angle_tolerance_deg

          deviation_mm = [
            face_plane_deviation_mm(face_a, face_b),
            face_plane_deviation_mm(face_b, face_a)
          ].max
          return nil if deviation_mm > plane_tolerance_mm

          {
            plane_deviation_mm: deviation_mm,
            angle_deg: angle_deg
          }
        rescue StandardError
          nil
        end

        # Returns groups keyed by the unordered pair of adjacent faces. Every
        # shared edge between the same two faces belongs to one group, including
        # boundaries split by T-junction vertices or other intermediate points.
        def coplanar_shared_edge_groups(
          entities,
          plane_tolerance_mm:,
          angle_tolerance_deg:,
          ignored_group_signatures: {}
        )
          groups = {}

          entities.grep(@edge_class).each do |edge|
            next unless edge&.valid? && edge.faces.length == 2

            face_a, face_b = edge.faces
            face_ids = [stable_entity_id(face_a), stable_entity_id(face_b)]
            self_adjacent = face_a.equal?(face_b) || face_ids.uniq.length == 1
            pair_key = if self_adjacent
                         [:self, face_ids.first]
                       else
                         [:pair, *face_ids.sort]
                       end

            group = (groups[pair_key] ||= {
              key: pair_key,
              self_adjacent: self_adjacent,
              faces: [face_a, face_b],
              edges: []
            })
            group[:edges] << edge
          end

          groups.values.filter_map do |group|
            signature = coplanar_shared_edge_group_signature(group)
            next if ignored_group_signatures[signature]

            metrics = coplanar_face_pair_metrics(
              group[:faces][0],
              group[:faces][1],
              plane_tolerance_mm: plane_tolerance_mm,
              angle_tolerance_deg: angle_tolerance_deg
            )
            next unless metrics

            group.merge(
              signature: signature,
              max_plane_deviation_mm: metrics[:plane_deviation_mm],
              max_angle_deg: metrics[:angle_deg]
            )
          end
        end

        def coplanar_shared_edge_group_signature(group)
          [
            group[:key],
            group[:edges].map { |edge| stable_entity_id(edge) }.sort
          ]
        end

        # A group list becomes stale after any earlier merge in the same pass.
        # Re-read every edge and require the complete group to still separate the
        # same unordered face pair immediately before erasing it.
        def refresh_coplanar_shared_edge_group(
          group,
          plane_tolerance_mm:,
          angle_tolerance_deg:
        )
          edges = Array(group[:edges])
          return nil if edges.empty? || edges.any? { |edge| !edge&.valid? }

          current_pairs = edges.map do |edge|
            faces = Array(edge.faces)
            next nil unless faces.length == 2 && faces.all?(&:valid?)

            ids = faces.map { |face| stable_entity_id(face) }
            self_adjacent = faces[0].equal?(faces[1]) || ids.uniq.length == 1
            key = self_adjacent ? [:self, ids.first] : [:pair, *ids.sort]
            { key: key, self_adjacent: self_adjacent, faces: faces }
          end
          return nil if current_pairs.any?(&:nil?)
          return nil unless current_pairs.map { |entry| entry[:key] }.uniq == [group[:key]]

          first = current_pairs.first
          metrics = coplanar_face_pair_metrics(
            first[:faces][0],
            first[:faces][1],
            plane_tolerance_mm: plane_tolerance_mm,
            angle_tolerance_deg: angle_tolerance_deg
          )
          return nil unless metrics

          group.merge(
            self_adjacent: first[:self_adjacent],
            faces: first[:faces],
            signature: coplanar_shared_edge_group_signature(group),
            max_plane_deviation_mm: metrics[:plane_deviation_mm],
            max_angle_deg: metrics[:angle_deg]
          )
        end

        # Tracks only the local topology affected by each successful edge-group
        # removal. A complete geometry_counts reference remains authoritative at
        # fixed intervals and at every pass boundary. Any disagreement raises and
        # is rolled back by the enclosing normalization operation.
        def remove_coplanar_shared_edges(
          entities,
          plane_tolerance_mm:,
          angle_tolerance_deg:
        )
          removed = 0
          removed_groups = 0
          unchanged = 0
          ignored_group_signatures = {}
          pass_reports = []
          max_deviation_mm = 0.0
          max_angle_deg = 0.0
          multi_edge_group_count = 0
          max_shared_edges_per_group = 0
          protected_fan_transition_group_count = 0
          protected_fan_transition_edge_count = 0
          collinear_vertex_removal_count = 0
          groups_done = 0
          last_reference_group = -1
          topology = geometry_counts(entities)

          MAX_COPLANAR_PASSES.times do |pass_index|
            groups = coplanar_shared_edge_groups(
              entities,
              plane_tolerance_mm: plane_tolerance_mm,
              angle_tolerance_deg: angle_tolerance_deg,
              ignored_group_signatures: ignored_group_signatures
            )
            break if groups.empty?

            pass_removed = 0
            pass_removed_groups = 0
            pass_collapsed_vertices = 0
            groups.each do |group|
              current = refresh_coplanar_shared_edge_group(
                group,
                plane_tolerance_mm: plane_tolerance_mm,
                angle_tolerance_deg: angle_tolerance_deg
              )
              next unless current

              edges = current[:edges]
              signature = current[:signature]
              protection = CoplanarCollinearEdgePolicy.protected_fan_transition_edges(
                faces: current[:faces],
                internal_edges: edges,
                angle_tolerance_deg: angle_tolerance_deg
              )
              if protection[:edge_count].positive?
                ignored_group_signatures[signature] = true
                unchanged += edges.length
                protected_fan_transition_group_count += 1
                protected_fan_transition_edge_count += edges.length
                next
              end

              merge_seed_vertices = edges.flat_map do |edge|
                Array(edge.vertices)
              end.uniq
              topology_before = topology.dup
              affected_before, seed_vertices =
                coplanar_incremental_affected_before(current)
              local_before = coplanar_incremental_edge_counts(affected_before)
              face_context = coplanar_incremental_face_context(
                current,
                affected_before
              )

              begin
                entities.erase_entities(edges)
              rescue ArgumentError => error
                ignored_group_signatures[signature] = true
                unchanged += edges.length
                next if error.message.to_s.downcase.include?('not planar')

                raise
              end

              affected_after = coplanar_incremental_affected_after(
                affected_before,
                seed_vertices
              )
              local_after = coplanar_incremental_edge_counts(affected_after)
              faces_after = coplanar_incremental_faces_after(
                affected_after,
                face_context[:outside]
              )
              face_reduction = face_context[:count] - faces_after
              expected_reduction = current[:self_adjacent] ? 0 : 1

              unless face_reduction == expected_reduction
                raise DestructiveCoplanarCleanupError,
                      "Coplanar edge-group removal was destructive at " \
                      "tolerance=#{plane_tolerance_mm}mm " \
                      "angle=#{current[:max_angle_deg]}deg " \
                      "deviation=#{current[:max_plane_deviation_mm]}mm " \
                      "shared_edges=#{edges.length} " \
                      "self_adjacent=#{current[:self_adjacent]}: " \
                      "local faces #{face_context[:count]} -> #{faces_after}"
              end

              topology_after = coplanar_incremental_apply_delta(
                topology_before,
                local_before,
                local_after,
                face_reduction
              )

              if closed_surface?(topology_before) && !closed_surface?(topology_after)
                raise DestructiveCoplanarCleanupError,
                      "Coplanar edge-group removal opened the shell: " \
                      "shared_edges=#{edges.length} " \
                      "before=#{topology_before.inspect} " \
                      "after=#{topology_after.inspect}"
              end

              if topology_anomaly_score(topology_after) >
                 topology_anomaly_score(topology_before)
                raise DestructiveCoplanarCleanupError,
                      "Coplanar edge-group removal increased topology anomalies: " \
                      "shared_edges=#{edges.length} " \
                      "before=#{topology_before.inspect} " \
                      "after=#{topology_after.inspect}"
              end

              if edges.any?(&:valid?)
                raise DestructiveCoplanarCleanupError,
                      "Coplanar edge-group removal left shared edges valid: " \
                      "remaining=#{edges.count(&:valid?)} total=#{edges.length}"
              end

              begin
                collapse =
                  CoplanarCollinearEdgePolicy.collapse_degree_two_collinear_vertices!(
                    entities,
                    merge_seed_vertices,
                    angle_tolerance_deg: angle_tolerance_deg
                  )
              rescue CoplanarCollinearEdgePolicy::CollapseError => error
                raise DestructiveCoplanarCleanupError, error.message
              end

              collapsed_count = collapse[:collapsed_vertex_count].to_i
              if collapsed_count.positive?
                collapsed_topology = geometry_counts(entities)
                if closed_surface?(topology_after) &&
                   !closed_surface?(collapsed_topology)
                  raise DestructiveCoplanarCleanupError,
                        "Collinear vertex collapse opened the shell: " \
                        "vertices=#{collapse[:collapsed_vertex_ids].inspect} " \
                        "before=#{topology_after.inspect} " \
                        "after=#{collapsed_topology.inspect}"
                end
                if topology_anomaly_score(collapsed_topology) >
                   topology_anomaly_score(topology_after)
                  raise DestructiveCoplanarCleanupError,
                        "Collinear vertex collapse increased topology anomalies: " \
                        "vertices=#{collapse[:collapsed_vertex_ids].inspect} " \
                        "before=#{topology_after.inspect} " \
                        "after=#{collapsed_topology.inspect}"
                end
                topology = collapsed_topology
              else
                topology = topology_after
              end
              edge_count = edges.length
              pass_removed += edge_count
              pass_removed_groups += 1
              removed += edge_count
              removed_groups += 1
              groups_done += 1
              pass_collapsed_vertices += collapsed_count
              collinear_vertex_removal_count += collapsed_count
              multi_edge_group_count += 1 if edge_count > 1
              max_shared_edges_per_group = [max_shared_edges_per_group, edge_count].max
              max_deviation_mm = [
                max_deviation_mm,
                current[:max_plane_deviation_mm]
              ].max
              max_angle_deg = [max_angle_deg, current[:max_angle_deg]].max

              next unless (
                groups_done % COPLANAR_INCREMENTAL_REFERENCE_INTERVAL
              ).zero?

              topology = coplanar_incremental_reference!(entities, topology)
              last_reference_group = groups_done
            end

            break if pass_removed.zero?

            if last_reference_group != groups_done
              topology = coplanar_incremental_reference!(entities, topology)
              last_reference_group = groups_done
            end

            pass_reports << {
              pass: pass_index + 1,
              removed_edges: pass_removed,
              removed_groups: pass_removed_groups,
              collapsed_collinear_vertices: pass_collapsed_vertices
            }
          end

          remaining = coplanar_shared_edge_groups(
            entities,
            plane_tolerance_mm: plane_tolerance_mm,
            angle_tolerance_deg: angle_tolerance_deg,
            ignored_group_signatures: ignored_group_signatures
          )
          unless remaining.empty?
            sample = remaining.first(10).map do |group|
              {
                face_pair: group[:key],
                shared_edges: group[:edges].length
              }
            end
            raise DestructiveCoplanarCleanupError,
                  "Coplanar shared-edge merge did not converge: " \
                  "remaining_groups=#{remaining.length} sample=#{sample.inspect}"
          end

          all_remaining = coplanar_shared_edge_groups(
            entities,
            plane_tolerance_mm: plane_tolerance_mm,
            angle_tolerance_deg: angle_tolerance_deg
          )
          ignored_remaining = all_remaining.count do |group|
            ignored_group_signatures[group[:signature]]
          end

          {
            removed_edges: removed,
            removed_groups: removed_groups,
            unchanged_edges: unchanged,
            ignored_groups: ignored_remaining,
            passes: pass_reports,
            max_plane_deviation_mm: max_deviation_mm,
            max_angle_deg: max_angle_deg,
            multi_edge_group_count: multi_edge_group_count,
            max_shared_edges_per_group: max_shared_edges_per_group,
            protected_fan_transition_group_count:
              protected_fan_transition_group_count,
            protected_fan_transition_edge_count:
              protected_fan_transition_edge_count,
            collinear_vertex_removal_count: collinear_vertex_removal_count,
            fallback_reason: nil
          }
        end

        def coplanar_incremental_affected_before(current)
          face_edges = Array(current[:faces]).flat_map do |face|
            face&.valid? ? Array(face.edges) : []
          rescue StandardError
            []
          end
          seed_edges = coplanar_incremental_unique(
            face_edges + Array(current[:edges])
          )
          vertices = seed_edges.flat_map do |edge|
            Array(edge.vertices)
          rescue StandardError
            []
          end.uniq
          [
            coplanar_incremental_unique(
              seed_edges + coplanar_incremental_incident(vertices)
            ),
            vertices
          ]
        end

        def coplanar_incremental_affected_after(before, vertices)
          survivors = Array(before).select do |edge|
            edge&.valid?
          rescue StandardError
            false
          end
          coplanar_incremental_unique(
            survivors + coplanar_incremental_incident(vertices)
          )
        end

        def coplanar_incremental_incident(vertices)
          Array(vertices).flat_map do |vertex|
            vertex.respond_to?(:edges) ? Array(vertex.edges) : []
          rescue StandardError
            []
          end
        end

        def coplanar_incremental_unique(items)
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

        def coplanar_incremental_face_context(current, affected)
          local = coplanar_incremental_unique(Array(current[:faces]))
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

        def coplanar_incremental_faces_after(affected, outside)
          faces = Array(affected).flat_map do |edge|
            Array(edge.faces)
          rescue StandardError
            []
          end
          coplanar_incremental_unique(faces).count do |face|
            !outside[stable_entity_id(face)]
          end
        end

        def coplanar_incremental_edge_counts(items)
          edges = coplanar_incremental_unique(items)
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
            when 0
              result[:wire_edges] += 1
            when 1
              result[:boundary_edges] += 1
            when 2
              begin
                if edge.reversed_in?(faces[0]) == edge.reversed_in?(faces[1])
                  result[:orientation_conflicts] += 1
                end
              rescue StandardError
                nil
              end
            else
              result[:overused_edges] += 1
            end
          rescue StandardError
            next
          end
          result
        end

        def coplanar_incremental_apply_delta(
          before,
          local_before,
          local_after,
          face_reduction
        )
          after = before.dup
          after[:faces] = before[:faces].to_i - face_reduction
          COPLANAR_INCREMENTAL_EDGE_KEYS.each do |key|
            after[key] = before[key].to_i +
                         local_after[key].to_i -
                         local_before[key].to_i
          end

          negative = COPLANAR_INCREMENTAL_TOPOLOGY_KEYS.select do |key|
            after[key].to_i.negative?
          end
          unless negative.empty?
            raise DestructiveCoplanarCleanupError,
                  "Incremental coplanar topology became negative: " \
                  "#{negative.inspect} #{after.inspect}"
          end

          after
        end

        def coplanar_incremental_reference!(entities, predicted)
          actual = geometry_counts(entities)
          mismatch = {}
          COPLANAR_INCREMENTAL_TOPOLOGY_KEYS.each do |key|
            next if predicted[key].to_i == actual[key].to_i

            mismatch[key] = [predicted[key], actual[key]]
          end
          unless mismatch.empty?
            raise DestructiveCoplanarCleanupError,
                  "Incremental coplanar topology differs from full reference: " \
                  "#{mismatch.inspect}"
          end

          actual
        end
      end
    end
  end
end
