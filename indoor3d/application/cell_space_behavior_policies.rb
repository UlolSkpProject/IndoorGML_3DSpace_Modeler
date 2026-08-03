# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceBehaviorPolicies
        module ExplicitDemotionPolicy
          DICTIONARY_NAME = 'ULOL_Indoor3D_Policy'
          AUTO_CONVERSION_DISABLED_KEY = 'cell_space_auto_conversion_disabled'

          module_function

          def disabled?(entity)
            return false unless entity&.respond_to?(:get_attribute)

            entity.get_attribute(
              DICTIONARY_NAME,
              AUTO_CONVERSION_DISABLED_KEY,
              false
            ) == true
          rescue StandardError
            false
          end

          def disable!(entity)
            return false unless entity&.respond_to?(:set_attribute)

            entity.set_attribute(
              DICTIONARY_NAME,
              AUTO_CONVERSION_DISABLED_KEY,
              true
            )
            disabled?(entity)
          rescue StandardError
            false
          end

          def enable!(entity)
            return true unless entity
            return true unless entity.respond_to?(:delete_attribute)

            entity.delete_attribute(
              DICTIONARY_NAME,
              AUTO_CONVERSION_DISABLED_KEY
            )
            !disabled?(entity)
          rescue StandardError
            false
          end
        end

        module IndoorModelCellSpaceBehavior
          private

          # SketchUp may deliver InstanceObserver events after the bulk operation
          # has committed. Those events describe writes already handled by the
          # batch and must not create a second transparent/property transaction.
          def with_bulk_cell_space_conversion
            generation = @bulk_cell_space_observer_settle_generation.to_i + 1
            @bulk_cell_space_observer_settle_generation = generation
            @bulk_cell_space_observer_settling = true
            super
          ensure
            schedule_bulk_cell_space_observer_settle_release(generation)
          end

          def observer_routing_suppressed?
            return true if @bulk_cell_space_observer_settling == true

            super
          end

          # An explicit demotion is stronger than Tag-based automatic conversion.
          # Keep the user's Tag, but persist an opt-out outside the IndoorGML
          # attribute dictionary so finish/load normalization cannot recreate it.
          def demote_cell_space_to_solid_group(cell_space)
            group = super
            return group unless group&.valid?

            if IndoorCore.tag_cell_space_type_and_category(group)
              unless ExplicitDemotionPolicy.disable!(group)
                raise 'CellSpace automatic-conversion opt-out could not be persisted'
              end
            else
              ExplicitDemotionPolicy.enable!(group)
            end
            group
          end

          def auto_convert_tagged_primal_entity(entity)
            return false if ExplicitDemotionPolicy.disabled?(entity)

            super
          end

          def target_for_tagged_child(child, parent_target)
            return nil if ExplicitDemotionPolicy.disabled?(child)

            super
          end

          # A successful explicit conversion re-enables the normal Tag policy.
          def register_cell_space(cell_space)
            result = super
            if result != false && cell_space&.sketchup_group
              unless ExplicitDemotionPolicy.enable!(cell_space.sketchup_group)
                IndoorCore::Logger.puts(
                  '[IndoorGML] CellSpace auto-conversion policy marker cleanup failed'
                )
              end
            end
            result
          end

          # Lock/material and other untracked SketchUp changes can raise
          # onChangeEntity. There is no persistent work to perform for :etc, so an
          # empty transparent operation only pollutes the Undo stack.
          def handle_cell_space_etc_changed(cell_space)
            entity = cell_space&.sketchup_group
            if entity&.valid?
              IndoorCore::Logger.puts(
                "[IndoorGML] CellSpace change ignored as etc: " \
                "entity_id=#{entity.entityID} name=#{entity.name}"
              )
              remember_cell_space_change_snapshot(entity)
            end
            false
          end

          def schedule_bulk_cell_space_observer_settle_release(generation)
            unless defined?(UI) && UI.respond_to?(:start_timer)
              release_bulk_cell_space_observer_settle(generation)
              return
            end

            UI.start_timer(0, false) do
              release_bulk_cell_space_observer_settle(generation)
            end
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Bulk observer settle release scheduling failed: " \
              "#{e.class}: #{e.message}"
            )
            release_bulk_cell_space_observer_settle(generation)
          end

          def release_bulk_cell_space_observer_settle(generation)
            return false unless @bulk_cell_space_observer_settle_generation == generation

            @bulk_cell_space_observer_settling = false
            true
          end
        end
      end

      if defined?(IndoorModel)
        IndoorModel.prepend(
          CellSpaceBehaviorPolicies::IndoorModelCellSpaceBehavior
        ) unless IndoorModel.ancestors.include?(
          CellSpaceBehaviorPolicies::IndoorModelCellSpaceBehavior
        )
      end
    end
  end
end
