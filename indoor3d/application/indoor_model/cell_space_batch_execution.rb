# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        # Execution-layer override for the batch lifecycle. The global CellSpace
        # environment is prepared exactly once by the operation owner before any
        # per-entity converter runs, so a global preparation failure aborts the
        # whole batch instead of being misclassified as one source failure.
        module CellSpaceBatchExecution
          private

          def build_batch_conversion_service(
            jobs,
            fallback_target:,
            original_active_path:,
            preserve_source:,
            operation_name:,
            activate_root_context:,
            local_grid_v2:
          )
            model = @model || Sketchup.active_model
            active_path = ActivePathController.new(model, logger: IndoorCore::Logger)
            created = []
            lifecycle = local_grid_v2 ?
              cell_space_lifecycle_service_local_grid_v2 :
              cell_space_lifecycle_service

            BulkCellSpaceConversionService.new(
              model: model,
              jobs: jobs,
              fallback_target: fallback_target,
              target_entities: model.entities,
              converter: proc do |source, target_type, target_category, target_storey|
                cell_space = lifecycle.create_from_group_deferred(
                  source,
                  cell_type: target_type,
                  category_code: target_category,
                  storey: target_storey
                )
                created << cell_space
                cell_space
              end,
              synchronize_all: proc do
                # Persist every newly-created CellSpace once before topology starts,
                # preserving the old topology-visible attribute state and the
                # existing IndoorModel snapshot side effects. The batch dedup cache
                # then turns repeated transition/state persistence for unchanged
                # CellSpaces into no-ops.
                @attribute_serializer.with_cell_space_write_flush do
                  created.each do |cell_space|
                    next unless cell_space&.valid?

                    write_attributes(cell_space)
                  end
                end
                apply_cell_space_materials_batch(created)
                synchronize_topology_after_bulk_conversion
              end,
              apply_lock_policy: proc { apply_indoor_lock_policy },
              runtime_snapshot: proc { bulk_conversion_runtime_snapshot },
              runtime_restore: proc { |snapshot| restore_bulk_conversion_runtime(snapshot) },
              apply_guards: proc do |&block|
                @attribute_serializer.with_cell_space_write_dedup(defer_writes: true) do
                  with_bulk_cell_space_conversion(&block)
                end
              end,
              operation_runner: proc do |name, **options, &block|
                with_indoor_model_operation(name, **options) do
                  prepare_cell_space_batch_environment
                  block.call
                end
              end,
              restore_active_path: proc { active_path.restore(original_active_path, close_when_nil: true) },
              activate_root_context: activate_root_context ? proc { active_path.close_to_root } : nil,
              clear_dirty_topology: proc { clear_bulk_dirty_topology },
              logger: IndoorCore::Logger,
              labeler: ConversionMessageFormatter.method(:group_label),
              preserve_source: preserve_source,
              operation_name: operation_name
            )
          end
        end
      end
    end
  end
end
