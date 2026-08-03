# frozen_string_literal: true

require_relative '../cell_space_auto_conversion_policy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        # Removes IndoorGML semantics from one or more CellSpaces through one
        # staged batch. A single CellSpace is treated as a one-item batch.
        module CellSpaceDemotionBatch
          private

          def perform_selected_cell_space_demotion(cell_spaces)
            plan = build_cell_space_demotion_batch_plan(cell_spaces)
            return false if plan[:cell_spaces].empty?

            runtime_snapshot = bulk_conversion_runtime_snapshot
            begin
              with_validation_focus_mutation_batch do
                with_indoor_model_operation(
                  'Remove Selected CellSpace IndoorGML Attributes'
                ) do
                  sync do
                    erase_guard do
                      execute_cell_space_demotion_batch(plan)
                    end
                  end
                end
              end
            rescue StandardError => error
              restore_bulk_conversion_runtime(runtime_snapshot) if runtime_snapshot
              IndoorCore::Logger.puts(
                "[IndoorGML] Selected CellSpace batch demotion failed: " \
                "#{error.class}: #{error.message}"
              )
              UiFeedback.defer_modal("IndoorGML 속성 제거 실패:\n#{error.message}")
              return false
            end

            untrack_demoted_primal_entities(plan[:groups])
            refresh_after_selected_cell_space_demotion
            IndoorCore::Logger.puts(
              '[IndoorGML] CellSpace batch demotion complete: ' \
              "cells=#{plan[:cell_spaces].length} " \
              "states=#{plan[:states].length} " \
              "transitions=#{plan[:transitions].length}"
            )
            true
          end

          def build_cell_space_demotion_batch_plan(cell_spaces)
            valid_cell_spaces = Array(cell_spaces)
              .select { |cell_space| cell_space&.valid? }
              .uniq
            groups = valid_cell_spaces.map(&:sketchup_group)
            unless groups.all? { |group| group&.valid? }
              raise ArgumentError, 'One or more CellSpace groups are no longer valid'
            end

            states = valid_cell_spaces.map(&:duality_state).compact.uniq
            transitions = Array(@transitions).select do |transition|
              states.any? { |state| transition.connected_to?(state) }
            end.uniq

            {
              cell_spaces: valid_cell_spaces,
              groups: groups,
              states: states,
              transitions: transitions
            }
          end

          def execute_cell_space_demotion_batch(plan)
            clear_cell_space_materials_for_demotion_batch(plan[:groups])
            erase_transitions_for_demotion_batch(plan[:transitions])
            erase_states_for_demotion_batch(plan[:states])
            unregister_cell_spaces_for_demotion_batch(plan[:cell_spaces])
            erase_adjacency_for_demotion_batch(plan[:cell_spaces])
            clear_indoor_attributes_for_demotion_batch(plan[:groups])
            consume_demoted_group_tags_batch(plan[:groups])
            cleanup_demoted_group_runtime_tracking_batch(plan[:groups])
          end

          def clear_cell_space_materials_for_demotion_batch(groups)
            Array(groups).each do |group|
              raise 'CellSpace material cleanup failed' unless
                clear_cell_space_materials(group)
            end
          end

          def erase_transitions_for_demotion_batch(transitions)
            Array(transitions).each do |transition|
              pair_key = transition_cell_pair_key(transition)
              if pair_key
                @feature_registry.delete_transition_for_pair(pair_key)
                @feature_registry.delete_adjacent_pair(pair_key)
              end
              erase_transition(transition)
            end
          end

          def erase_states_for_demotion_batch(states)
            Array(states).each do |state|
              state.erase! if state&.valid?
              unregister_state(state)
            end
          end

          def unregister_cell_spaces_for_demotion_batch(cell_spaces)
            Array(cell_spaces).each { |cell_space| unregister_cell_space(cell_space) }
          end

          # This only removes adjacency records involving the demoted cells. It
          # never runs adjacency discovery or topology synchronization.
          def erase_adjacency_for_demotion_batch(cell_spaces)
            Array(cell_spaces).each do |cell_space|
              erase_adjacency_for_cell_space(cell_space)
            end
          end

          # Attribute cleanup intentionally runs after Transition/State removal.
          # Transition removal persists surviving neighbors' transition ids and
          # may temporarily write the selected State attributes again.
          def clear_indoor_attributes_for_demotion_batch(groups)
            Array(groups).each do |group|
              @attribute_serializer.clear_indoor_gml_attributes(group)
              unless indoor_gml_attribute_dictionary_empty?(group)
                raise 'IndoorGML AttributeDictionary cleanup was incomplete'
              end
            end
          end

          # The outer classification Tag is input data, not persistent CellSpace
          # identity. Consume it during demotion so finish/load normalization
          # cannot recreate the removed CellSpace. Nested geometry Tags are left
          # untouched.
          def consume_demoted_group_tags_batch(groups)
            Array(groups).each do |group|
              unless consume_demoted_group_tag(group)
                raise 'Demoted CellSpace Tag could not be moved to Untagged'
              end
            end
          end

          def consume_demoted_group_tag(group)
            return false unless CellSpaceAutoConversionPolicy.consume_tag!(
              group,
              model: @model
            )

            CellSpaceAutoConversionPolicy.enable!(group)
          end

          def cleanup_demoted_group_runtime_tracking_batch(groups)
            Array(groups).each do |group|
              @scene_group_guard.untrack(group) if @scene_group_guard
              @cell_space_change_snapshots.delete(entity_observer_key(group)) if
                @cell_space_change_snapshots
              unlock_indoor_entity(group)
            end
          end
        end
      end
    end
  end
end
