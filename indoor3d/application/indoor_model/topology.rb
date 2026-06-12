# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module Topology
          def update_transitions_for_state(state)
            return if state.nil?

            @transitions.each do |transition|
              next unless transition.connected_to?(state)

              update_transition(transition)
              write_transition_attributes(transition)
            end
          end

          private

          def connect_states(state1, state2)
            ensure_space_features_groups(transparent: true)

            cell1 = state1&.duality_cell
            cell2 = state2&.duality_cell
            return nil if cell1.nil? || cell2.nil?

            create_or_update_transition_for_pair(cell1, cell2)
          end

          def synchronize_adjacency_and_transitions_for_cell_space(cell_space)
            @adjacency_service.synchronize_for(cell_space)
          end

          def mark_cell_space_dirty(cell_space)
            @dirty_cell_space_pids ||= {}
            return unless cell_space&.valid?

            entity = cell_space.valid_sketchup_group
            return unless entity

            @dirty_cell_space_pids[entity.persistent_id] = true
            schedule_dirty_cell_space_sync
          rescue StandardError => e
            puts "[IndoorGML] CellSpace dirty mark failed: #{e.class}: #{e.message}"
          end

          def schedule_dirty_cell_space_sync
            @dirty_cell_space_pids ||= {}
            return if @cell_space_sync_scheduled

            @cell_space_sync_scheduled = true
            UI.start_timer(0, false) do
              flush_dirty_cell_space_sync
            end
          end

          def flush_dirty_cell_space_sync
            @dirty_cell_space_pids ||= {}
            pids = @dirty_cell_space_pids.keys
            @dirty_cell_space_pids.clear
            @cell_space_sync_scheduled = false
            return if pids.empty?

            with_transparent_cell_space_operation('IndoorGML Dirty CellSpace Sync') do
              sync do
                pids.each do |persistent_id|
                  cell_space = @feature_registry.find_cell_space_by_persistent_id(persistent_id)
                  next unless cell_space&.valid?

                  synchronize_adjacency_and_transitions_for_cell_space(cell_space)
                  remember_cell_space_change_snapshot(cell_space.sketchup_group)
                end
              end
            end
            Sketchup.active_model.active_view.invalidate if Sketchup.active_model&.active_view
          rescue StandardError => e
            @cell_space_sync_scheduled = false
            puts "[IndoorGML] Dirty CellSpace sync failed: #{e.class}: #{e.message}"
          end

          def erase_adjacency_for_cell_space(cell_space)
            @adjacency_service.erase_for(cell_space)
          end

          def create_or_update_transition_for_pair(cell1, cell2)
            return nil if cell1.nil? || cell2.nil?
            return nil if cell1 == cell2
            return nil unless cell1.valid? && cell2.valid?
            return nil unless cell1.duality_state&.valid? && cell2.duality_state&.valid?

            pair_key = cell_pair_key(cell1, cell2)
            transition = @feature_registry.transition_for_pair(pair_key)
            unless transition&.valid?
              transition = Transition.new(
                cell1.duality_state,
                cell2.duality_state,
                nil,
                cell1: cell1,
                cell2: cell2
              )
              @feature_registry.add_transition(transition, pair_key: pair_key)
            end

            return nil unless update_transition(transition)

            register_transition_with_states(transition)
            write_transition_attributes(transition)
            transition
          end

          def erase_transition_for_pair_key(pair_key)
            transition = @feature_registry.delete_transition_for_pair(pair_key)
            return if transition.nil?

            erase_transition(transition)
            @feature_registry.delete_adjacent_pair(pair_key)
          end

          def erase_transition(transition)
            return if transition.nil?

            unregister_transition_from_states(transition)
            transition.erase!
            @feature_registry.remove_transition(transition)
          end

          def cell_pair_key(cell1, cell2)
            @adjacency_service.cell_pair_key(cell1, cell2)
          end

          def transition_cell_pair_key(transition)
            if transition.cell1 && transition.cell2
              return cell_pair_key(transition.cell1, transition.cell2)
            end

            return nil if transition.cell1_id.to_s.empty? || transition.cell2_id.to_s.empty?

            [transition.cell1_id, transition.cell2_id].sort.join(':')
          end

          def register_transition_with_states(transition)
            transition.state1.add_transition(transition)
            transition.state2.add_transition(transition)
            write_state_attributes(transition.state1)
            write_state_attributes(transition.state2)
          end

          def unregister_transition_from_states(transition)
            transition.state1.remove_transition(transition) if transition.state1
            transition.state2.remove_transition(transition) if transition.state2
            write_state_attributes(transition.state1) if transition.state1&.valid?
            write_state_attributes(transition.state2) if transition.state2&.valid?
          end

          def erase_transitions_for_state(state)
            return if state.nil?

            @transitions.select { |transition| transition.connected_to?(state) }.each do |transition|
              pair_key = transition_cell_pair_key(transition)
              if pair_key
                @feature_registry.delete_transition_for_pair(pair_key)
                @feature_registry.delete_adjacent_pair(pair_key)
              end
              erase_transition(transition)
            end
          end

          def update_transition(transition)
            updated = transition.update(
              state_local_position(transition.state1),
              state_local_position(transition.state2)
            )
            refresh_transition_waypoint_candidates(transition) if updated
            updated
          end

          def refresh_transition_waypoint_candidates(transition)
            candidates = transition_waypoint_candidates(transition)
            unless candidates.empty?
              transition.set_waypoint_candidates(
                candidates,
                point1: state_local_position(transition.state1),
                point2: state_local_position(transition.state2)
              )
            end
          rescue StandardError => e
            puts "[IndoorGML] Transition waypoint candidate refresh failed: #{e.class}: #{e.message}"
          end

          def transition_waypoint_candidates(transition)
            return [] unless transition.cell1&.valid? && transition.cell2&.valid?

            world_candidates = Utils::Geometry.common_face_waypoint_candidates(
              transition.cell1.sketchup_group,
              transition.cell2.sketchup_group
            )
            world_candidates.filter_map { |candidate| waypoint_candidate_to_primal_local(candidate) }
          end

          def world_point_to_primal_local(point)
            return point unless @primal_group&.valid?

            point.transform(@primal_group.transformation.inverse)
          end

          def waypoint_candidate_to_primal_local(candidate)
            return world_point_to_primal_local(candidate) if candidate.is_a?(Geom::Point3d)
            return nil unless candidate.is_a?(Hash)

            point = candidate[:point]
            return nil unless point.is_a?(Geom::Point3d)

            {
              point: world_point_to_primal_local(point),
              normal1: world_vector_to_primal_local(candidate[:normal1] || candidate[:normal]),
              normal2: world_vector_to_primal_local(candidate[:normal2])
            }
          end

          def world_vector_to_primal_local(vector)
            return vector unless vector.is_a?(Geom::Vector3d)
            return vector unless @primal_group&.valid?

            transformed = vector.transform(@primal_group.transformation.inverse)
            transformed.normalize! if transformed.length > 0.001
            transformed
          end

          def rebuild_runtime_transitions_from_cell_adjacency
            @adjacency_service.synchronize_all
          end
        end
      end
    end
  end
end
