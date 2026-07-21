# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(
          :topology_grid_source_inventory_before_boundary_common_refinement_v2
        )
          alias_method(
            :topology_grid_source_inventory_before_boundary_common_refinement_v2,
            :topology_grid_source_inventory
          )
        end

        unless private_method_defined?(
          :capture_normalized_source_face_constraints_before_boundary_common_refinement_topology_v2
        )
          alias_method(
            :capture_normalized_source_face_constraints_before_boundary_common_refinement_topology_v2,
            :capture_normalized_source_face_constraints
          )
        end

        # Boundary common refinement changes the authoritative ordered Face loops.
        # Therefore it must be visible while grid targets are still being selected,
        # not only later during source-Face reconstruction.
        #
        # The previous order was:
        #   choose targets from original loops
        #   -> insert overlap endpoints
        #   -> triangulate a loop the target solver never validated
        #
        # This wrapper expands the same source Face loops before the Face-local
        # topology solver runs. Any floor/ceil target candidate must therefore keep
        # the refined loop simple, oriented, and non-self-intersecting.
        def topology_grid_source_inventory(entities, axis_plane_plan)
          face_records, source_mm_by_key, initial_targets =
            topology_grid_source_inventory_before_boundary_common_refinement_v2(
              entities,
              axis_plane_plan
            )

          refinement =
            source_boundary_common_refinement_topology_data(entities)
          expanded_records =
            source_boundary_expand_topology_face_records(
              face_records,
              refinement[:inventory],
              refinement[:split_entries],
              source_mm_by_key,
              initial_targets,
              axis_plane_plan
            )

          [
            expanded_records,
            source_mm_by_key,
            initial_targets
          ]
        end

        def capture_normalized_source_face_constraints(
          entities,
          axis_plane_plan,
          short_edge_plan
        )
          capture_normalized_source_face_constraints_before_boundary_common_refinement_topology_v2(
            entities,
            axis_plane_plan,
            short_edge_plan
          )
        ensure
          # The same normalizer instance may be reused after geometry mutation.
          # Never carry source Edge entities or loop ordering into another run.
          @source_boundary_common_refinement_topology_cache = nil
        end

        def source_boundary_common_refinement_topology_data(entities)
          cache = @source_boundary_common_refinement_topology_cache
          if cache && cache[:entities_object_id] == entities.object_id
            return cache
          end

          inventory =
            source_boundary_common_refinement_inventory(entities)
          split_entries, relations =
            source_boundary_common_refinement_splits(inventory[:edges])

          @source_boundary_common_refinement_topology_cache = {
            entities_object_id: entities.object_id,
            inventory: inventory,
            split_entries: split_entries,
            relations: relations
          }
        end

        # Pure record transformation. No SketchUp mutation occurs here.
        def source_boundary_expand_topology_face_records(
          face_records,
          inventory,
          split_entries,
          source_mm_by_key,
          initial_targets,
          axis_plane_plan
        )
          inventory_faces = inventory[:faces].to_h do |face_record|
            [face_record[:face_key], face_record]
          end

          face_records.map do |face_record|
            inventory_face = inventory_faces[face_record[:face_key]]
            next face_record unless inventory_face

            expanded_loops =
              face_record[:loops].each_with_index.map do |loop, loop_index|
                inventory_loop = inventory_face[:loops][loop_index]
                next loop unless inventory_loop

                expanded_keys = []
                inventory_loop[:edge_indices].each do |edge_index|
                  edge = inventory[:edges].fetch(edge_index)
                  expanded_keys << edge[:first][:source_key]

                  Array(split_entries[edge_index]).each do |split|
                    entry = split[:point_entry]
                    key = entry[:source_key]
                    expanded_keys << key
                    source_mm_by_key[key] ||= entry[:point_mm]
                    initial_targets[key] ||=
                      grid_indices(
                        normalized_target_before_topology_grid_v2(
                          entry[:point],
                          axis_plane_plan
                        )
                      )
                  end
                end

                expanded_keys =
                  source_boundary_compact_topology_source_keys(expanded_keys)
                loop.merge(source_keys: expanded_keys)
              end

            face_record.merge(loops: expanded_loops)
          end
        end

        def source_boundary_compact_topology_source_keys(keys)
          compact = []
          keys.each do |key|
            compact << key if compact.empty? || compact.last != key
          end
          compact.pop if compact.length > 1 && compact.first == compact.last
          compact
        end
      end
    end
  end
end
