# frozen_string_literal: true

require_relative '../topology_coordinator'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module Topology
          def validation_focus_topology_dirty?
            @validation_focus_topology_dirty == true
          end

          def mark_validation_focus_topology_dirty
            @validation_focus_topology_dirty = true
          end

          def clear_validation_focus_topology_dirty
            @validation_focus_topology_dirty = false
          end

          def synchronize_validation_focus_row_topology
            return nil unless validation_focus_row_local_topology_sync?

            if validation_focus_mutation_batch_active?
              @validation_focus_topology_sync_pending = true
              mark_validation_focus_topology_dirty
              return {}
            end

            perform_validation_focus_row_topology_sync
          end

          def flush_validation_focus_row_topology_sync
            return nil unless @validation_focus_topology_sync_pending

            @validation_focus_topology_sync_pending = false
            perform_validation_focus_row_topology_sync
          end

          def discard_validation_focus_row_topology_sync
            @validation_focus_topology_sync_pending = false
          end

          def validation_focus_mutation_batch_active?
            @validation_focus_mutation_depth.to_i.positive?
          end

          private

          def perform_validation_focus_row_topology_sync
            return nil unless validation_focus_row_local_topology_sync?

            cell_spaces = validation_focus_highlight_cell_spaces
            metrics = topology_coordinator.synchronize_within(cell_spaces)
            mark_validation_focus_topology_dirty
            metrics
          rescue StandardError => e
            mark_validation_focus_topology_dirty
            IndoorCore::Logger.puts "[IndoorGML] Validation focus row topology sync failed: #{e.class}: #{e.message}"
            nil
          end

          public

          def synchronize_validation_focus_topology_if_dirty
            return true unless validation_focus_topology_dirty?

            with_indoor_model_operation('IndoorGML Validation Focus Topology Sync') do
              sync { topology_coordinator.synchronize_all }
            end
            dirty_topology_queue.clear
            dirty_topology_queue.unschedule!
            clear_validation_focus_topology_dirty
            invalidate_overlay_transition_points
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Validation focus full topology sync failed: #{e.class}: #{e.message}"
            false
          end

          private

          def synchronize_adjacency_and_transitions_for_cell_space(cell_space)
            if validation_focus_row_local_topology_sync?
              mark_validation_focus_topology_dirty
              return synchronize_validation_focus_row_topology
            end

            topology_coordinator.synchronize_for(cell_space)
          end

          def mark_cell_space_dirty(cell_space)
            return unless cell_space&.valid?

            if validation_focus_row_local_topology_sync?
              mark_validation_focus_topology_dirty
              if @editor_session.validation_focus_highlight_row_include_cell?(cell_space)
                synchronize_validation_focus_row_topology
              end
              return
            end

            entity = cell_space.valid_sketchup_group
            return unless entity

            dirty_topology_queue.mark(entity.persistent_id)
            schedule_dirty_cell_space_sync
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace dirty mark failed: #{e.class}: #{e.message}"
          end

          def schedule_dirty_cell_space_sync
            return if dirty_topology_queue.scheduled?

            dirty_topology_queue.schedule!
            generation = current_dirty_cell_space_sync_generation
            UI.start_timer(0, false) do
              next unless generation == current_dirty_cell_space_sync_generation
              if dirty_sync_replay_pending?
                dirty_topology_queue.clear
                dirty_topology_queue.unschedule!
                next
              end

              flush_dirty_cell_space_sync
            end
          end

          def flush_dirty_cell_space_sync
            return if dirty_sync_replay_pending?

            if validation_focus_row_local_topology_sync?
              dirty_topology_queue.clear
              dirty_topology_queue.unschedule!
              mark_validation_focus_topology_dirty
              synchronize_validation_focus_row_topology
              return
            end

            pids = dirty_topology_queue.persistent_ids
            dirty_topology_queue.clear
            dirty_topology_queue.unschedule!
            return if pids.empty?

            processing_index = nil
            with_transparent_cell_space_operation('IndoorGML Dirty CellSpace Sync') do
              sync do
                pids.each_with_index do |persistent_id, index|
                  processing_index = index
                  cell_space = @feature_registry.find_cell_space_by_persistent_id(persistent_id)
                  next unless cell_space&.valid?

                  synchronize_adjacency_and_transitions_for_cell_space(cell_space)
                  remember_cell_space_change_snapshot(cell_space.sketchup_group)
                end
              end
            end
            processing_index = nil
            Sketchup.active_model.active_view.invalidate if Sketchup.active_model&.active_view
            invalidate_overlay_transition_points
          rescue StandardError => e
            requeue_dirty_cell_space_pids(pids, processing_index)
            dirty_topology_queue.unschedule!
            schedule_dirty_cell_space_sync unless dirty_topology_queue.empty?
            IndoorCore::Logger.puts "[IndoorGML] Dirty CellSpace sync failed: #{e.class}: #{e.message}"
          end

          def requeue_dirty_cell_space_pids(pids, failed_index)
            dirty_topology_queue.requeue_from(pids, failed_index)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Dirty CellSpace requeue failed: #{e.class}: #{e.message}"
          end

          def invalidate_dirty_cell_space_sync!
            dirty_topology_queue.invalidate!
          end

          def current_dirty_cell_space_sync_generation
            dirty_topology_queue.generation
          end

          def dirty_sync_replay_pending?
            respond_to?(:transaction_replay_pending?) && transaction_replay_pending?
          rescue StandardError
            false
          end

          def erase_adjacency_for_cell_space(cell_space)
            result = topology_coordinator.erase_for(cell_space)
            mark_validation_focus_topology_dirty if validation_focus_row_selected?
            result
          end

          def validation_focus_row_local_topology_sync?
            validation_focus_active? && validation_focus_row_selected?
          rescue StandardError
            false
          end

          def validation_focus_row_selected?
            !@editor_session.validation_focus_highlight_row_id.to_s.empty?
          rescue StandardError
            false
          end

          def create_or_update_transition_for_pair(cell1, cell2)
            return nil if cell1.nil? || cell2.nil?
            return nil if cell1 == cell2
            return nil unless cell1.valid? && cell2.valid?

            return nil unless cell1.navigable? && cell2.navigable?

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
            invalidate_overlay_transition_points
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
            invalidate_overlay_transition_points
          end

          def cell_pair_key(cell1, cell2)
            topology_coordinator.cell_pair_key(cell1, cell2)
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
              state_root_local_position(transition.state1),
              state_root_local_position(transition.state2)
            )
            refresh_transition_waypoint_candidates(transition) if updated
            updated
          end

          def refresh_transition_waypoint_candidates(transition)
            candidates = transition_waypoint_candidates(transition)
            unless candidates.empty?
              transition.set_waypoint_candidates(
                candidates,
                point1: state_root_local_position(transition.state1),
                point2: state_root_local_position(transition.state2)
              )
            end
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Transition waypoint candidate refresh failed: #{e.class}: #{e.message}"
          end

          def transition_waypoint_candidates(transition)
            return [] unless transition.cell1&.valid? && transition.cell2&.valid?

            candidates = AdjacencyService::GeometryQuery.common_face_waypoint_candidates(
              transition.cell1.sketchup_group,
              transition.cell2.sketchup_group,
              state1_point: state_root_local_position(transition.state1),
              state2_point: state_root_local_position(transition.state2),
              transformation1: cell_space_root_local_transformation(transition.cell1),
              transformation2: cell_space_root_local_transformation(transition.cell2)
            )
            candidates.filter_map { |candidate| normalize_root_local_waypoint_candidate(candidate, transition) }
          end

          def state_root_local_position(state)
            group = state&.duality_cell&.sketchup_group
            return state.position unless group&.valid?

            cell_space_root_local_transformation(state.duality_cell).origin
          rescue StandardError
            state&.position || ORIGIN
          end

          def cell_space_root_local_transformation(cell_space)
            group = cell_space&.sketchup_group
            return Geom::Transformation.new unless group&.valid?

            Utils::Transformation.entity_transformation_in_root(group, @primal_group)
          end

          def normalize_root_local_waypoint_candidate(candidate, transition)
            normalized = if candidate.is_a?(Geom::Point3d)
                           { point: candidate, normal1: nil, normal2: nil }
                         elsif candidate.is_a?(Hash)
                           point = candidate[:point]
                           return nil unless point.is_a?(Geom::Point3d)

                           {
                             point: point,
                             normal1: normalized_root_local_vector(candidate[:normal1] || candidate[:normal]),
                             normal2: normalized_root_local_vector(candidate[:normal2])
                           }
                         end
            return nil unless normalized
            return nil unless plausible_root_local_waypoint?(normalized[:point], transition)

            normalized
          end

          def normalized_root_local_vector(vector)
            return vector unless vector.is_a?(Geom::Vector3d)

            normalized = vector.clone
            normalized.normalize! if normalized.length > 0.001
            normalized
          rescue StandardError
            nil
          end

          def plausible_root_local_waypoint?(point, transition)
            point1 = state_root_local_position(transition.state1)
            point2 = state_root_local_position(transition.state2)
            return true unless point1.is_a?(Geom::Point3d) && point2.is_a?(Geom::Point3d)

            midpoint = Geom::Point3d.new(
              (point1.x + point2.x) / 2.0,
              (point1.y + point2.y) / 2.0,
              (point1.z + point2.z) / 2.0
            )
            state_distance = point1.distance(point2)
            max_distance = [state_distance * 2.0, 500.mm].max
            midpoint.distance(point) <= max_distance
          end

          def rebuild_runtime_transitions_from_cell_adjacency
            metrics = topology_coordinator.synchronize_all
            clear_validation_focus_topology_dirty
            metrics
          end

          def rebuild_runtime_transitions_from_cell_adjacency_without_persistence
            metrics = topology_coordinator.synchronize_all(
              transition_builder: method(:create_or_update_runtime_transition_for_pair),
              transition_eraser: method(:erase_runtime_transition_for_pair_key)
            )
            clear_validation_focus_topology_dirty
            metrics
          end

          def create_or_update_runtime_transition_for_pair(cell1, cell2)
            return nil if cell1.nil? || cell2.nil?
            return nil if cell1 == cell2
            return nil unless cell1.valid? && cell2.valid?

            return nil unless cell1.navigable? && cell2.navigable?

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

            register_runtime_transition_with_states(transition)
            transition
          end

          def erase_runtime_transition_for_pair_key(pair_key)
            transition = @feature_registry.delete_transition_for_pair(pair_key)
            return if transition.nil?

            unregister_runtime_transition_from_states(transition)
            transition.erase!
            @feature_registry.remove_transition(transition)
            @feature_registry.delete_adjacent_pair(pair_key)
          end

          def register_runtime_transition_with_states(transition)
            transition.state1.add_transition(transition)
            transition.state2.add_transition(transition)
          end

          def unregister_runtime_transition_from_states(transition)
            transition.state1.remove_transition(transition) if transition.state1
            transition.state2.remove_transition(transition) if transition.state2
          end

          def topology_coordinator
            @topology_coordinator ||= TopologyCoordinator.new(
              adjacency_service: @adjacency_service,
              dirty_queue: legacy_dirty_topology_queue
            )
          end

          def dirty_topology_queue
            topology_coordinator.dirty_queue
          end

          def legacy_dirty_topology_queue
            queue = DirtyTopologyQueue.new
            return queue unless instance_variable_defined?(:@dirty_cell_space_pids) ||
                                instance_variable_defined?(:@cell_space_sync_scheduled) ||
                                instance_variable_defined?(:@dirty_cell_space_sync_generation)

            queue.restore!(
              persistent_ids: Hash(@dirty_cell_space_pids),
              scheduled: @cell_space_sync_scheduled == true,
              generation: @dirty_cell_space_sync_generation.to_i
            )
            queue
          end
        end
      end
    end
  end
end
