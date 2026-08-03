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

          def auto_convert_tagged_descendants(container, accumulated_transformation)
            return false if ExplicitDemotionPolicy.disabled?(container)

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
        end

        # BulkCellSpaceConversionService normally restores the active path after
        # its SketchUp operation has already committed. SketchUp can then record
        # lock/name/property writes triggered by the path callback as a second
        # "Properties" Undo item. Wrap the existing operation runner so a
        # successful path restore happens immediately before commit. Rollback and
        # exception paths retain the original post-abort restore ordering.
        module BulkCellSpaceConversionPreCommitActivePathRestore
          def initialize(*arguments, **keywords)
            super(*arguments, **keywords)
            install_precommit_active_path_restore
          end

          def call
            @production_active_path_restore_consumed = false
            super
          ensure
            @production_active_path_restore_consumed = false
          end

          private

          def install_precommit_active_path_restore
            return if @production_precommit_active_path_restore_installed
            return unless @operation_runner&.respond_to?(:call)
            return unless @restore_active_path&.respond_to?(:call)

            @production_precommit_active_path_restore_installed = true
            original_operation_runner = @operation_runner
            original_restore_active_path = @restore_active_path

            @restore_active_path = proc do
              restore_active_path_once(original_restore_active_path)
            end

            @operation_runner = proc do |name, **options, &work|
              rollback_if = options[:rollback_if]
              rollback_evaluated = false
              rollback_decision = false
              cached_rollback_if = proc do
                unless rollback_evaluated
                  rollback_decision = rollback_if&.call == true
                  rollback_evaluated = true
                end
                rollback_decision
              end

              wrapped_options = options.dup
              wrapped_options[:rollback_if] = cached_rollback_if if rollback_if

              original_operation_runner.call(name, **wrapped_options) do
                result = work.call
                restore_active_path_once(original_restore_active_path) unless cached_rollback_if.call
                result
              end
            rescue StandardError
              # A failed commit/operation must be allowed to retry restoration from
              # the service's existing rescue path after runtime rollback.
              @production_active_path_restore_consumed = false
              raise
            end
          end

          def restore_active_path_once(callback)
            return true if @production_active_path_restore_consumed

            callback.call
            @production_active_path_restore_consumed = true
            true
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Active path restore failed before CellSpace commit: " \
              "#{e.class}: #{e.message}"
            )
            false
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

      if defined?(BulkCellSpaceConversionService)
        BulkCellSpaceConversionService.prepend(
          CellSpaceBehaviorPolicies::BulkCellSpaceConversionPreCommitActivePathRestore
        ) unless BulkCellSpaceConversionService.ancestors.include?(
          CellSpaceBehaviorPolicies::BulkCellSpaceConversionPreCommitActivePathRestore
        )
      end
    end
  end
end
