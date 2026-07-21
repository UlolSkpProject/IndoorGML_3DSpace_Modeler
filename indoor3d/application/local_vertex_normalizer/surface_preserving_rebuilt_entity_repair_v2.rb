# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(
          :repair_rebuilt_entity_before_surface_preservation_v2
        )
          alias_method(
            :repair_rebuilt_entity_before_surface_preservation_v2,
            :repair_rebuilt_entity_before_rollback
          )
        end

        # Runs SketchUp-specific solid repairs only when each individual mutation
        # preserves the validated in-memory surface. A rejected mutation is restored
        # from the last accepted triangle snapshot before the next strategy runs.
        def repair_rebuilt_entity_before_rollback(entity, entities)
          checkpoint = @validated_rebuild_surface_checkpoint
          return repair_rebuilt_entity_before_surface_preservation_v2(entity, entities) unless
            checkpoint &&
            checkpoint[:surface_equivalent] == true &&
            checkpoint[:entities_object_id] == entities.object_id

          expected_records = Array(checkpoint[:validated_records])
          if expected_records.empty?
            raise TopologyChangedError,
                  'Validated rebuilt-surface checkpoint has no retained triangle records'
          end

          initial_records, initial_validation =
            surface_preserving_repair_snapshot!(entities, expected_records)
          initial_topology = geometry_counts(entities)
          report = {
            attempted: false,
            strategy: :surface_preserving_stepwise_repair,
            initial_topology: initial_topology,
            initial_mesh: initial_validation[:mesh],
            surface_border: { repairs: 0, skipped: true },
            reverse_faces: { reversed_faces: 0, component_count: 0, skipped: true },
            external_faces: { removed_faces: 0, attempts: 0, skipped: true },
            stray_edges: { removed_edges: 0, skipped: true },
            rejected_steps: [],
            accepted_steps: [],
            final_topology: nil,
            manifold: false,
            surface_preserved: true
          }

          if manifold_entity_with_closed_topology?(entity, initial_topology)
            report[:final_topology] = initial_topology
            report[:manifold] = true
            return report
          end

          report[:attempted] = true
          accepted_records = initial_records
          steps = [
            [:reverse_faces, -> { repair_reverse_faces(entities) }],
            [:stray_edges, -> { remove_stray_edges(entities) }],
            [:surface_border, -> { stitch_surface_borders(entities) }],
            [:external_faces, -> { remove_external_faces_conservatively(entities) }]
          ]

          steps.each do |name, operation|
            before_records = accepted_records
            before_topology = geometry_counts(entities)
            result = nil

            begin
              result = operation.call || {}
              accepted_records, validation =
                surface_preserving_repair_snapshot!(entities, expected_records)
              after_topology = geometry_counts(entities)
              report[name] = result.merge(
                skipped: false,
                accepted: true,
                topology_before: before_topology,
                topology_after: after_topology,
                mesh: validation[:mesh]
              )
              report[:accepted_steps] << name
            rescue StandardError => error
              restore_surface_preserving_repair_snapshot!(
                entities,
                before_records,
                expected_records
              )
              accepted_records = before_records
              report[name] = (result || {}).merge(
                skipped: false,
                accepted: false,
                topology_before: before_topology,
                topology_after_rejected_attempt: geometry_counts(entities),
                error: "#{error.class}: #{error.message}"
              )
              report[:rejected_steps] << {
                step: name,
                error: "#{error.class}: #{error.message}"
              }
            end

            current_topology = geometry_counts(entities)
            if manifold_entity_with_closed_topology?(entity, current_topology)
              report[:final_topology] = current_topology
              report[:manifold] = true
              return report
            end
          end

          final_topology = geometry_counts(entities)
          report[:final_topology] = final_topology
          report[:manifold] = manifold_entity_with_closed_topology?(
            entity,
            final_topology
          )
          return report if report[:manifold]

          manifold_value = begin
            entity.respond_to?(:manifold?) ? entity.manifold? : :unsupported
          rescue StandardError => error
            "#{error.class}: #{error.message}"
          end
          raise TopologyChangedError,
                'Surface-preserving rebuilt-entity repair could not satisfy ' \
                "SketchUp manifold contract: manifold=#{manifold_value.inspect} " \
                "topology=#{final_topology.inspect} " \
                "accepted=#{report[:accepted_steps].inspect} " \
                "rejected=#{report[:rejected_steps].inspect}"
        end

        def surface_preserving_repair_snapshot!(entities, expected_records)
          diagnostics = {}
          records = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: diagnostics
          )
          if diagnostics[:duplicate_count].to_i.positive?
            raise TopologyChangedError,
                  'Surface-preserving repair produced duplicate Triangle faces: ' \
                  "count=#{diagnostics[:duplicate_count]} " \
                  "samples=#{Array(diagnostics[:samples]).first(10).inspect}"
          end

          records, degenerate_report = repair_degenerate_source_triangles(records)
          mesh = validate_normalized_triangle_mesh!(records)
          equivalence = verify_normalized_surface_equivalence!(
            expected_records,
            records
          )
          [
            records,
            {
              mesh: mesh,
              surface_equivalence: equivalence,
              degenerate_repair: degenerate_report
            }
          ]
        end

        def restore_surface_preserving_repair_snapshot!(
          entities,
          records,
          expected_records
        )
          erase_source_geometry(entities)
          build = rebuild_triangles(entities, records)
          unless build[:added_faces] == records.length &&
                 build[:skipped_collinear].to_i.zero?
            raise ReconstructionError,
                  'Could not restore rejected surface-preserving repair: ' \
                  "#{build.inspect} expected=#{records.length}"
          end

          restored, = surface_preserving_repair_snapshot!(
            entities,
            expected_records
          )
          restored
        end
      end
    end
  end
end
