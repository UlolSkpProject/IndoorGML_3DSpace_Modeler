# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
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

        def coplanar_edge_metrics(edge, plane_tolerance_mm:, angle_tolerance_deg:)
          return nil unless edge&.valid? && edge.faces.length == 2

          face_a, face_b = edge.faces
          metrics = coplanar_face_pair_metrics(
            face_a,
            face_b,
            plane_tolerance_mm: plane_tolerance_mm,
            angle_tolerance_deg: angle_tolerance_deg
          )
          metrics&.merge(edge: edge)
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
            groups.each do |group|
              current = refresh_coplanar_shared_edge_group(
                group,
                plane_tolerance_mm: plane_tolerance_mm,
                angle_tolerance_deg: angle_tolerance_deg
              )
              next unless current

              edges = current[:edges]
              signature = current[:signature]
              topology_before = geometry_counts(entities)
              faces_before = topology_before[:faces]

              begin
                entities.erase_entities(edges)
              rescue ArgumentError => e
                ignored_group_signatures[signature] = true
                unchanged += edges.length
                next if e.message.to_s.downcase.include?('not planar')

                raise
              end

              topology_after = geometry_counts(entities)
              faces_after = topology_after[:faces]
              face_reduction = faces_before - faces_after
              expected_reduction = current[:self_adjacent] ? 0 : 1

              unless face_reduction == expected_reduction
                raise DestructiveCoplanarCleanupError,
                      "Coplanar edge-group removal was destructive at " \
                      "tolerance=#{plane_tolerance_mm}mm " \
                      "angle=#{current[:max_angle_deg]}deg " \
                      "deviation=#{current[:max_plane_deviation_mm]}mm " \
                      "shared_edges=#{edges.length} " \
                      "self_adjacent=#{current[:self_adjacent]}: " \
                      "faces #{faces_before} -> #{faces_after}"
              end

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

              edge_count = edges.length
              pass_removed += edge_count
              pass_removed_groups += 1
              removed += edge_count
              removed_groups += 1
              multi_edge_group_count += 1 if edge_count > 1
              max_shared_edges_per_group = [max_shared_edges_per_group, edge_count].max
              max_deviation_mm = [
                max_deviation_mm,
                current[:max_plane_deviation_mm]
              ].max
              max_angle_deg = [max_angle_deg, current[:max_angle_deg]].max
            end

            break if pass_removed.zero?

            pass_reports << {
              pass: pass_index + 1,
              removed_edges: pass_removed,
              removed_groups: pass_removed_groups
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
            fallback_reason: nil
          }
        end
      end
    end
  end
end
