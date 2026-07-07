# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module RuntimeSupport
          def refresh_runtime_data
            with_indoor_model_operation('IndoorGML Refresh Runtime Data', transparent: true) do
              next true if guard_active?(:@refreshing_runtime)

              with_guard_flag(:@refreshing_runtime) do
                sync do
                  restore_runtime_from_current_model
                  recenter_runtime_cell_spaces
                  rebuild_runtime_transitions_from_cell_adjacency
                end
                invalidate_overlay_transition_points
                apply_indoor_lock_policy()
                @editor_session.apply_display_state()
                IndoorCore::Logger.puts "[IndoorGML] Runtime refreshed: cells=#{@cell_spaces.length}, states=#{@states.length}, transitions=#{@transitions.length}"
                true
              end
            end
          end

          def reconcile_runtime_after_transaction(source: nil, generation: nil)
            return true if guard_active?(:@transaction_reconciliation)

            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            metrics = nil
            with_guard_flag(:@transaction_reconciliation) do
              sync do
                restore_runtime_from_current_model
                rebuild_runtime_transitions_from_cell_adjacency_without_persistence
                prune_runtime_observer_tracking
                rebuild_scene_group_guard_tracking
              end
              @editor_session.reconcile_after_transaction(@model, source: source) if @editor_session&.respond_to?(:reconcile_after_transaction)
              metrics = {
                source: source,
                generation: generation,
                cell_spaces: diagnostic_count(@cell_spaces),
                states: diagnostic_count(@states),
                transitions: diagnostic_count(@transitions),
                pair_comparison_count: @adjacency_service&.last_metrics&.fetch(:pair_comparison_count, 0).to_i,
                total_duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
              }
            end
            metrics
          end

          def begin_transaction_replay(source:, generation:)
            @transaction_replay_pending = true
            @transaction_replay_source = source
            @transaction_replay_generation = generation
            invalidate_dirty_cell_space_sync! if respond_to?(:invalidate_dirty_cell_space_sync!, true)
            true
          end

          def finish_transaction_replay(generation:)
            return false unless @transaction_replay_generation == generation

            clear_transaction_replay!
            true
          end

          def clear_transaction_replay!
            @transaction_replay_pending = false
            @transaction_replay_source = nil
            @transaction_replay_generation = nil
            true
          end

          def transaction_replay_pending?
            @transaction_replay_pending == true
          end

          def transaction_replay_generation
            @transaction_replay_generation
          end

          def transaction_replay_source
            @transaction_replay_source
          end

          def diagnostic_snapshot
            {
              cell_spaces: diagnostic_count(@cell_spaces),
              states: diagnostic_count(@states),
              transitions: diagnostic_count(@transitions),
              editing: @editor_session&.editing? == true,
              cell_space_geometry_editing: @editor_session&.cell_space_geometry_editing? == true,
              active_path: current_active_path_kind,
              dirty_topology_count: @dirty_cell_space_pids&.length.to_i,
              topology_sync_scheduled: @cell_space_sync_scheduled == true,
              guards: {
                syncing: @syncing == true,
                erasing: @erasing == true,
                restoring: @refreshing_runtime == true,
                transaction_replay_pending: transaction_replay_pending?,
                relocating: @relocating_entity == true,
                constraining: @constraining_space_features == true,
                finishing_editing: @finishing_editing == true
              }
            }
          end

          def with_space_feature_constraint
            with_guard_flag(:@constraining_space_features) { yield }
          end

          def with_runtime_observer_suppression
            sync { yield }
          end

          private

          def diagnostic_count(features)
            Array(features).count do |feature|
              feature.respond_to?(:valid?) ? feature.valid? : !feature.nil?
            rescue StandardError
              false
            end
          end

          def current_active_path_kind
            model = @model || (defined?(Sketchup) ? Sketchup.active_model : nil)
            return :unavailable unless model&.respond_to?(:active_path)

            path = model.active_path
            return :root if path.nil? || path.empty?

            valid_path = Array(path).select { |entity| entity&.valid? }
            return :root if valid_path.empty?
            return :primal if @primal_group&.valid? && valid_path == [@primal_group]

            if @primal_group&.valid? && valid_path.first == @primal_group
              return :cell_space_geometry if valid_path.length > 1

              return :primal
            end

            :other
          rescue StandardError
            :unknown
          end

          def with_indoor_model_operation(name, transparent: false)
            return yield if @indoor_operation_depth.to_i.positive?
            return yield if indoor_operation_suppressed?

            model = @model || Sketchup.active_model
            return yield unless model
            if model.respond_to?(:active_operation_name) && model.active_operation_name.to_s.length.positive?
              return yield
            end

            operation_started = false
            @indoor_operation_depth = @indoor_operation_depth.to_i + 1
            begin
              operation_started = model.start_operation(name, true, false, transparent)
              result = yield
              model.commit_operation if operation_started
              operation_started = false
              result
            rescue StandardError
              model.abort_operation if operation_started
              raise
            ensure
              @indoor_operation_depth = [@indoor_operation_depth.to_i - 1, 0].max
            end
          end

          def indoor_operation_suppressed?
            respond_to?(:observer_routing_suppressed?) && observer_routing_suppressed?
          rescue StandardError
            false
          end

          def bind_registry_collections
            @cell_spaces = @feature_registry.cell_spaces
            @states = @feature_registry.states
            @transitions = @feature_registry.transitions
          end

          def restore_runtime_from_current_model
            @model ||= Sketchup.active_model
            find_existing_space_features_groups
            reset_runtime_collections
            attach_existing_space_features_observers
            @runtime_restorer.restore(primal_group: @primal_group)
          end

          def reset_runtime_collections
            @feature_registry.reset!
            @cell_space_change_snapshots.clear
            @space_features_change_snapshots.clear
            @dirty_cell_space_pids.clear
            @cell_space_sync_scheduled = false
            bind_registry_collections
          end

          def prune_runtime_observer_tracking
            @cell_space_observed_ids ||= {}
            @space_features_observed_ids ||= {}
            @entities_observed_ids ||= {}

            current_cell_observer_keys = @cell_spaces.each_with_object({}) do |cell_space, keys|
              group = cell_space&.sketchup_group
              key = entity_observer_key(group)
              keys[key] = true if group&.valid? && key
            end
            @cell_space_observed_ids.select! { |key, _| current_cell_observer_keys[key] }

            current_space_feature_keys = {}
            key = entity_observer_key(@primal_group)
            current_space_feature_keys[key] = true if @primal_group&.valid? && key
            @space_features_observed_ids.select! { |observer_key, _| current_space_feature_keys[observer_key] }

            current_entities_keys = {}
            model = @model || Sketchup.active_model
            current_entities_keys[[:root, model.entities.object_id]] = true if model&.respond_to?(:entities) && model.entities
            current_entities_keys[[:primal, @primal_group.entities.object_id]] = true if @primal_group&.valid? && @primal_group.respond_to?(:entities)
            @entities_observed_ids.select! { |observer_key, _| current_entities_keys[observer_key] }
          end

          def rebuild_scene_group_guard_tracking
            tracking = {}
            tracking[@primal_group.persistent_id] = PRIMAL_GROUP_NAME if @primal_group&.valid?
            @cell_spaces.each do |cell_space|
              group = cell_space&.sketchup_group
              tracking[group.persistent_id] = group.name if group&.valid?
            end
            @scene_group_guard.restore!(tracking)
          end

          def bulk_conversion_runtime_snapshot
            {
              registry: @feature_registry.snapshot,
              primal_group: @primal_group,
              scene_group_guard: @scene_group_guard.snapshot,
              cell_space_change_snapshots: @cell_space_change_snapshots.dup,
              space_features_change_snapshots: @space_features_change_snapshots.dup,
              dirty_cell_space_pids: @dirty_cell_space_pids.dup,
              cell_space_sync_scheduled: @cell_space_sync_scheduled,
              cell_space_observed_ids: @cell_space_observed_ids.dup,
              space_features_observed_ids: @space_features_observed_ids.dup,
              entities_observed_ids: @entities_observed_ids.dup,
              state_instances: mutable_instance_snapshot(@states),
              transition_instances: mutable_instance_snapshot(@transitions)
            }
          end

          def restore_bulk_conversion_runtime(snapshot)
            restore_mutable_instances(snapshot[:state_instances])
            restore_mutable_instances(snapshot[:transition_instances])
            @feature_registry.restore!(snapshot[:registry])
            bind_registry_collections
            @primal_group = snapshot[:primal_group]
            @scene_group_guard.restore!(snapshot[:scene_group_guard])
            @cell_space_change_snapshots = snapshot[:cell_space_change_snapshots].dup
            @space_features_change_snapshots = snapshot[:space_features_change_snapshots].dup
            @dirty_cell_space_pids = snapshot[:dirty_cell_space_pids].dup
            @cell_space_sync_scheduled = snapshot[:cell_space_sync_scheduled]
            @cell_space_observed_ids = snapshot[:cell_space_observed_ids].dup
            @space_features_observed_ids = snapshot[:space_features_observed_ids].dup
            @entities_observed_ids = snapshot[:entities_observed_ids].dup
          end

          def mutable_instance_snapshot(objects)
            Array(objects).each_with_object({}) do |object, snapshot|
              next if object.nil?

              snapshot[object.object_id] = {
                object: object,
                variables: object.instance_variables.each_with_object({}) do |name, values|
                  values[name] = duplicate_runtime_value(object.instance_variable_get(name))
                end
              }
            end
          end

          def restore_mutable_instances(snapshot)
            Hash(snapshot).each_value do |entry|
              object = entry[:object]
              Hash(entry[:variables]).each do |name, value|
                object.instance_variable_set(name, duplicate_runtime_value(value))
              end
            end
          end

          def duplicate_runtime_value(value)
            case value
            when Array
              value.dup
            when Hash
              value.dup
            else
              value
            end
          end

          def recenter_runtime_cell_spaces
            @cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              recenter_cell_space_origin(cell_space)
              write_cell_space_attributes(cell_space)
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Runtime CellSpace recenter skipped: cell=#{cell_space&.id} #{e.class}: #{e.message}"
            end
          end

          def clear_indoor_gml_groups
            [@primal_group].each do |group|
              next unless group&.valid?

              unlock_indoor_entity(group)
              group.erase!
            end
            @primal_group = nil
            @cell_space_observed_ids.clear
            @space_features_observed_ids.clear
            @entities_observed_ids.clear
          end

          def stale_cell_space_runtime?(cell_space, entity)
            begin
              return true if cell_space.nil?
              return true unless cell_space.valid?
              return true unless cell_space.sketchup_group == entity
              return true unless cell_space.duality_state&.valid?

              false
            rescue StandardError
              true
            end
          end

          def refresh_and_find_cell_space(entity)
            refresh_runtime_data
            find_cell_space_for_entity(entity)
          end

          def defer_ui_message(message)
            UI.start_timer(0, false) do
              UI.messagebox(message)
            end
          end

          def write_space_features_attributes(group, feature)
            @attribute_serializer.write_space_features(group, feature)
          end

          def write_attributes(cell_space)
            @attribute_serializer.write_cell_space_and_state(cell_space)
            remember_cell_space_change_snapshot(cell_space.sketchup_group) if cell_space&.valid?
          end

          def write_cell_space_attributes(cell_space)
            @attribute_serializer.write_cell_space(cell_space)
            remember_cell_space_change_snapshot(cell_space.sketchup_group) if cell_space&.valid?
          end

          def write_state_attributes(state)
            @attribute_serializer.write_state(state)
          end

          def write_transition_attributes(transition)
            @attribute_serializer.write_transition(transition)
          end

          def indoor_gml_entity?(entity)
            @attribute_serializer.indoor_gml_entity?(entity)
          end

          def indoor_attribute(entity, key)
            @attribute_serializer.attribute(entity, key)
          end

          def indoor_feature(entity)
            @attribute_serializer.feature(entity)
          end

          def space_features_feature?(feature)
            feature == PRIMAL_GROUP_FEATURE
          end

          def converted_group?(sketchup_group)
            @attribute_serializer.converted_group?(sketchup_group)
          end

          def find_cell_space_for_entity(entity)
            @feature_registry.find_cell_space_for_entity(entity)
          end

          def default_storey_name
            CellSpace::DEFAULT_STOREY
          end

          def with_unlocked(entity)
            @editor_session.with_unlocked(entity) { yield }
          end

          def lock_indoor_entity(entity)
            @editor_session.lock_entity(entity)
          end

          def unlock_indoor_entity(entity)
            @editor_session.unlock_entity(entity)
          end

          def sync
            with_guard_flag(:@syncing) do
              yield
            end
          end

          def erase_guard
            with_guard_flag(:@erasing) do
              yield
            end
          end

          def guard_active?(flag)
            instance_variable_get(flag)
          end

          def with_guard_flag(flag)
            previous_value = instance_variable_get(flag)
            instance_variable_set(flag, true)
            yield
          ensure
            instance_variable_set(flag, previous_value)
          end

          def entity_observer_key(entity)
            return nil unless entity

            entity.object_id
          rescue StandardError
            nil
          end

          def delete_entity_observer_key(observed_ids, entity)
            return unless observed_ids && entity

            observed_ids.delete(entity_observer_key(entity))
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
