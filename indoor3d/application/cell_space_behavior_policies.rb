# frozen_string_literal: true

require_relative 'cell_space_auto_conversion_policy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceBehaviorPolicies
        # Compatibility alias for existing callers/tests.
        ExplicitDemotionPolicy = CellSpaceAutoConversionPolicy unless const_defined?(
          :ExplicitDemotionPolicy,
          false
        )

        # CellSpaceLifecycleService resolves type/category/storey from the source
        # Tag before initialize_scene is called. Consume the outer Group Tag at
        # this point so every successful manual/automatic Create path finishes on
        # Untagged without disturbing nested Face/Edge Tags.
        module CellSpaceLifecycleTagConsumption
          def initialize_scene(cell_space, storey: default_storey_name)
            group = cell_space&.sketchup_group
            unless CellSpaceAutoConversionPolicy.consume_tag!(group)
              raise 'CellSpace Tag could not be moved to Untagged'
            end
            unless CellSpaceAutoConversionPolicy.enable!(group)
              raise 'Legacy CellSpace automatic-conversion marker cleanup failed'
            end

            super
          end
        end

        module IndoorModelCellSpaceBehavior
          private

          # Explicit demotion must remove the same outer classification Tag that
          # Create consumes. Otherwise finish/load normalization sees the mapped
          # Tag and recreates the CellSpace.
          def demote_cell_space_to_solid_group(cell_space)
            group = super
            return group unless group&.valid?

            unless CellSpaceAutoConversionPolicy.consume_tag!(group, model: @model)
              raise 'Demoted CellSpace Tag could not be moved to Untagged'
            end
            unless CellSpaceAutoConversionPolicy.enable!(group)
              raise 'Legacy CellSpace automatic-conversion marker cleanup failed'
            end
            group
          end

          # Legacy marker checks remain so older files saved by the previous
          # marker-based policy are not automatically reconverted on first open.
          def auto_convert_tagged_primal_entity(entity)
            return false if CellSpaceAutoConversionPolicy.disabled?(entity)

            super
          end

          def auto_convert_tagged_descendants(container, accumulated_transformation)
            return false if CellSpaceAutoConversionPolicy.disabled?(container)

            super
          end

          def target_for_tagged_child(child, parent_target)
            return nil if CellSpaceAutoConversionPolicy.disabled?(child)

            super
          end

          # A successful explicit conversion clears any legacy marker. The outer
          # Tag itself is consumed earlier by CellSpaceLifecycleTagConsumption.
          def register_cell_space(cell_space)
            result = super
            if result != false && cell_space&.sketchup_group
              unless CellSpaceAutoConversionPolicy.enable!(cell_space.sketchup_group)
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

      if defined?(CellSpaceLifecycleContext)
        CellSpaceLifecycleContext.prepend(
          CellSpaceBehaviorPolicies::CellSpaceLifecycleTagConsumption
        ) unless CellSpaceLifecycleContext.ancestors.include?(
          CellSpaceBehaviorPolicies::CellSpaceLifecycleTagConsumption
        )
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
