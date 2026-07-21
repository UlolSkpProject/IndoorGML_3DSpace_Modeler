# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # Coplanar edge removal is attempted only on a closed rebuilt surface.
        # An open rebuild is left intact for the ordered step-10 repair sequence.
        # If cleanup damages a previously closed shell, the validated triangles
        # are rebuilt before continuing.
        def orient_and_merge_rebuilt_surface(entities, validated_triangles)
          topology_before = geometry_counts(entities)
          consistency = repair_reverse_faces(entities)
          axis_plane_merge = empty_coplanar_cleanup_report

          if closed_surface?(geometry_counts(entities))
            backup = validated_triangles.map(&:dup)
            begin
              axis_plane_merge = remove_coplanar_shared_edges(
                entities,
                plane_tolerance_mm: STRICT_COPLANAR_TOLERANCE_MM,
                angle_tolerance_deg: STRICT_COPLANAR_ANGLE_TOLERANCE_DEG
              )
              topology = geometry_counts(entities)
              unless closed_surface?(topology)
                raise DestructiveCoplanarCleanupError,
                      "Coplanar cleanup opened rebuilt shell: #{topology.inspect}"
              end
            rescue DestructiveCoplanarCleanupError, ArgumentError => error
              erase_source_geometry(entities)
              restored = rebuild_triangles(entities, backup)
              unless restored[:added_faces] == backup.length &&
                     restored[:skipped_collinear].zero?
                raise ReconstructionError,
                      "Could not restore surface after coplanar cleanup failure: " \
                      "#{restored.inspect}"
              end
              consistency = repair_reverse_faces(entities)
              axis_plane_merge = empty_coplanar_cleanup_report(
                fallback_reason: "#{error.class}: #{error.message}"
              )
            end
          else
            axis_plane_merge = empty_coplanar_cleanup_report(
              fallback_reason: :skipped_open_rebuilt_surface
            )
          end

          topology_after = geometry_counts(entities)
          orientation = {
            reversed_faces: consistency[:reversed_faces].to_i,
            consistency_reversed_faces:
              consistency[:consistency_reversed_faces].to_i,
            shell_component_count: consistency[:component_count].to_i,
            outward_reversed_faces: consistency[:outward_reversed_faces].to_i,
            signed_volume_before_mm3:
              consistency[:signed_volume_before_in3].to_f * (MM_PER_INCH**3),
            signed_volume_after_mm3:
              consistency[:signed_volume_after_in3].to_f * (MM_PER_INCH**3),
            topology_before: topology_before,
            topology_after: topology_after,
            error: consistency[:error]
          }
          axis_plane_merge[:merged_faces] = axis_plane_merge[:removed_groups] ||
            axis_plane_merge[:removed_edges]
          axis_plane_merge[:preserved_constrained_edges] = false
          [orientation, axis_plane_merge]
        end

        # Step 10. Each repair is bounded and accepted only when it improves the
        # entity topology. As soon as the group is again a manifold solid, later
        # destructive repair attempts are skipped.
        def repair_rebuilt_entity_before_rollback(entity, entities)
          report = {
            attempted: false,
            initial_topology: geometry_counts(entities),
            surface_border: { repairs: 0, skipped: true },
            reverse_faces: { reversed_faces: 0, component_count: 0, skipped: true },
            external_faces: { removed_faces: 0, attempts: 0, skipped: true },
            stray_edges: { removed_edges: 0, skipped: true },
            final_topology: nil,
            manifold: false
          }

          if manifold_entity_with_closed_topology?(entity, report[:initial_topology])
            report[:final_topology] = report[:initial_topology]
            report[:manifold] = true
            return report
          end

          report[:attempted] = true

          report[:surface_border] = attempt_entity_repair_step do
            stitch_surface_borders(entities)
          end
          return finish_entity_repair_report(report, entity, entities) if
            manifold_entity_with_closed_topology?(entity, geometry_counts(entities))

          report[:reverse_faces] = attempt_entity_repair_step do
            repair_reverse_faces(entities)
          end
          return finish_entity_repair_report(report, entity, entities) if
            manifold_entity_with_closed_topology?(entity, geometry_counts(entities))

          report[:external_faces] = attempt_entity_repair_step do
            remove_external_faces_conservatively(entities)
          end
          return finish_entity_repair_report(report, entity, entities) if
            manifold_entity_with_closed_topology?(entity, geometry_counts(entities))

          report[:stray_edges] = attempt_entity_repair_step do
            remove_stray_edges(entities)
          end
          finish_entity_repair_report(report, entity, entities)
        end

        def attempt_entity_repair_step
          result = yield
          (result || {}).merge(skipped: false)
        rescue StandardError => error
          {
            skipped: false,
            error: "#{error.class}: #{error.message}"
          }
        end

        def repair_reverse_faces(entities)
          consistency = orient_shell_faces_consistently(entities)
          outward = if closed_surface?(geometry_counts(entities)) &&
                       consistency[:component_count] == 1
                      orient_shell_outward(entities)
                    else
                      {
                        reversed_faces: 0,
                        signed_volume_before_in3: nil,
                        signed_volume_after_in3: nil
                      }
                    end
          {
            reversed_faces: consistency[:reversed_faces] + outward[:reversed_faces],
            consistency_reversed_faces: consistency[:reversed_faces],
            outward_reversed_faces: outward[:reversed_faces],
            component_count: consistency[:component_count],
            signed_volume_before_in3: outward[:signed_volume_before_in3],
            signed_volume_after_in3: outward[:signed_volume_after_in3]
          }
        rescue TopologyChangedError => error
          {
            reversed_faces: 0,
            component_count: 0,
            error: "#{error.class}: #{error.message}"
          }
        end

        # Removes only faces touching an overused edge and only when a trial
        # deletion strictly reduces the anomaly score. Rejected candidates are
        # restored with their original metadata.
        def remove_external_faces_conservatively(entities)
          removed_faces = 0
          removed_boundary_edges = 0
          attempts = 0
          ignored_signatures = {}

          while attempts < MAX_EXTERNAL_FACE_REPAIRS
            before = geometry_counts(entities)
            candidates = entities.grep(@face_class).select do |face|
              next false unless face&.valid?

              signature = face_signature(face)
              next false if ignored_signatures[signature]

              face.edges.any? { |edge| edge.faces.length > 2 }
            end
            break if candidates.empty?

            accepted = false
            candidates.each do |face|
              break if attempts >= MAX_EXTERNAL_FACE_REPAIRS

              attempts += 1
              signature = face_signature(face)
              record = face_record(face)
              candidate_edges = face.edges.dup
              face.erase!
              removed_candidate_edges = candidate_edges.count do |edge|
                next false unless edge&.valid? && edge.faces.empty?

                edge.erase!
                true
              end
              after = geometry_counts(entities)

              if topology_anomaly_score(after) < topology_anomaly_score(before) &&
                 after[:faces].positive?
                removed_faces += 1
                removed_boundary_edges += removed_candidate_edges
                accepted = true
                break
              end

              restored = entities.add_face(record[:points])
              unless restored&.valid?
                raise ReconstructionError,
                      "External-face trial could not restore rejected face: " \
                      "#{before.inspect} -> #{after.inspect}"
              end
              orient_face!(restored, record[:source_normal])
              apply_face_metadata(restored, record)
              ignored_signatures[signature] = true
            end
            break unless accepted
          end

          {
            removed_faces: removed_faces,
            removed_boundary_edges: removed_boundary_edges,
            attempts: attempts,
            limit_reached: attempts >= MAX_EXTERNAL_FACE_REPAIRS
          }
        end

        def face_signature(face)
          face.vertices.map { |vertex| grid_indices(vertex.position) }.sort
        end

        def remove_stray_edges(entities)
          edges = entities.grep(@edge_class).select do |edge|
            edge&.valid? && edge.faces.empty?
          end
          entities.erase_entities(edges) unless edges.empty?
          { removed_edges: edges.length }
        end

        def manifold_entity_with_closed_topology?(entity, topology)
          entity&.valid? &&
            entity.respond_to?(:manifold?) &&
            entity.manifold? == true &&
            closed_topology?(topology)
        rescue StandardError
          false
        end

        def finish_entity_repair_report(report, entity, entities)
          topology = geometry_counts(entities)
          report[:final_topology] = topology
          report[:manifold] = manifold_entity_with_closed_topology?(entity, topology)
          unless report[:manifold]
            raise TopologyChangedError,
                  "Local vertex reconstruction remained non-manifold after " \
                  "surface-border, reverse-face, external-face, and stray-edge " \
                  "repairs: #{entity_label(entity)} #{topology.inspect}"
          end
          report
        end
      end
    end
  end
end
