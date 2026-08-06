# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module CellSpaceTypeChangeOptimization
          TOPOLOGY_ACTION_SYNCHRONIZE = :synchronize
          TOPOLOGY_ACTION_ERASE_TRANSITIONS = :erase_transitions

          def change_cell_space_types(
            sketchup_groups,
            cell_type,
            category_code = nil,
            operation_name: 'Change CellSpace Types',
            progress: nil
          )
            plan = Array(sketchup_groups).map do |group|
              cell_space = find_cell_space_for_entity(group)
              raise ArgumentError, 'Selected entity is not a registered CellSpace' if cell_space.nil?
              raise ArgumentError, 'CellSpace is no longer valid' unless cell_space.valid?

              resolved_type, resolved_category = tag_cell_space_type_change_target(
                cell_space,
                cell_type,
                category_code
              )
              {
                cell_space: cell_space,
                cell_type: resolved_type,
                category_code: resolved_category,
                was_navigable: cell_space.navigable? == true,
                duality_state: cell_space.duality_state
              }
            end
            return [] if plan.empty?

            changed = []
            with_validation_focus_mutation_batch do
              with_bulk_cell_space_conversion do
                with_indoor_model_operation(operation_name, force: true) do
                  sync do
                    start_cell_space_type_change_stage(progress, plan.length)
                    plan.each_with_index do |entry, index|
                      cell_space_lifecycle_service.change_type(
                        entry[:cell_space],
                        cell_type: entry[:cell_type],
                        category_code: entry[:category_code]
                      )
                      changed << entry[:cell_space]
                      update_cell_space_type_change_stage(progress, index + 1, plan.length)
                    end
                    apply_cell_space_materials_batch(changed)
                    finish_cell_space_type_change_stage(progress, changed.length)

                    topology_plan = build_cell_space_type_change_topology_plan(plan)
                    apply_cell_space_type_change_topology(topology_plan, progress)
                    apply_indoor_lock_policy
                  end
                end
              end
            end
            changed
          end

          private

          def build_cell_space_type_change_topology_plan(plan)
            Array(plan).filter_map do |entry|
              is_navigable = entry[:cell_space].navigable? == true
              action = cell_space_type_change_topology_action(
                entry[:was_navigable],
                is_navigable
              )
              next if action.nil?

              entry.merge(action: action, is_navigable: is_navigable)
            end
          end

          def cell_space_type_change_topology_action(was_navigable, is_navigable)
            return TOPOLOGY_ACTION_SYNCHRONIZE if !was_navigable && is_navigable
            return TOPOLOGY_ACTION_ERASE_TRANSITIONS if was_navigable && !is_navigable

            nil
          end

          def apply_cell_space_type_change_topology(plan, progress)
            entries = Array(plan)
            return type_change_progress_update(progress, message: 'Topology 변경 없음') if entries.empty?

            type_change_progress_call(
              progress,
              :start_stage,
              'Adjacency/Transition 갱신',
              total: entries.length,
              message: "Topology 갱신: 0 / #{entries.length}",
              cancellable: false,
              metadata: { operation: :cell_space_type_change_topology }
            )

            entries.each_with_index do |entry, index|
              case entry[:action]
              when TOPOLOGY_ACTION_SYNCHRONIZE
                synchronize_adjacency_and_transitions_for_cell_space(entry[:cell_space])
              when TOPOLOGY_ACTION_ERASE_TRANSITIONS
                erase_transitions_for_state_preserving_adjacency(entry[:duality_state])
              end
              type_change_progress_call(
                progress,
                :update_stage,
                completed: index + 1,
                message: "Topology 갱신: #{index + 1} / #{entries.length}"
              )
            end

            type_change_progress_call(
              progress,
              :finish_stage,
              message: 'Adjacency/Transition 갱신 완료',
              telemetry: {
                synchronized_cell_spaces: entries.count do |entry|
                  entry[:action] == TOPOLOGY_ACTION_SYNCHRONIZE
                end,
                transition_only_removals: entries.count do |entry|
                  entry[:action] == TOPOLOGY_ACTION_ERASE_TRANSITIONS
                end
              }
            )
          end

          def erase_transitions_for_state_preserving_adjacency(state)
            return [] if state.nil?

            transitions = Array(@transitions).select do |transition|
              transition.connected_to?(state)
            end
            transitions.each do |transition|
              pair_key = transition_cell_pair_key(transition)
              @feature_registry.delete_transition_for_pair(pair_key) if pair_key
              erase_transition(transition)
            end
            if !transitions.empty? && respond_to?(:mark_validation_focus_topology_dirty)
              mark_validation_focus_topology_dirty
            end
            transitions
          end

          def start_cell_space_type_change_stage(progress, total)
            type_change_progress_call(
              progress,
              :start_stage,
              'CellSpace Type/재질 변경',
              total: total,
              message: "CellSpace Type 변경: 0 / #{total}",
              cancellable: false,
              metadata: { operation: :cell_space_type_change }
            )
          end

          def update_cell_space_type_change_stage(progress, completed, total)
            type_change_progress_call(
              progress,
              :update_stage,
              completed: completed,
              message: "CellSpace Type 변경: #{completed} / #{total}"
            )
          end

          def finish_cell_space_type_change_stage(progress, total)
            type_change_progress_call(
              progress,
              :finish_stage,
              message: "CellSpace Type/재질 변경 완료: #{total}개"
            )
          end

          def type_change_progress_update(progress, message:)
            type_change_progress_call(progress, :update, message: message)
          end

          def type_change_progress_call(progress, method_name, *arguments, **keywords)
            return nil unless progress&.respond_to?(:active?) && progress.active?
            return nil unless progress.respond_to?(method_name)

            progress.public_send(method_name, *arguments, **keywords)
          rescue StandardError => error
            IndoorCore::Logger.puts(
              "[IndoorGML] CellSpace type progress #{method_name} failed: " \
              "#{error.class}: #{error.message}"
            )
            nil
          end
        end
      end

      IndoorModel.prepend(
        IndoorModel::CellSpaceTypeChangeOptimization
      ) unless IndoorModel.ancestors.include?(
        IndoorModel::CellSpaceTypeChangeOptimization
      )
    end
  end
end
