# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Adapts the executor's model/world-space copy request into a direct copy
      # under IndoorGML_PrimalSpaceFeatures. The executor still owns source
      # isolation, attribute copying, success cleanup, and failure rollback.
      #
      # Input transformation contract:
      #   world = transformation
      #
      # Direct-child transformation contract:
      #   local = primal_world.inverse * world
      #   primal_world * local == world
      #
      # The returned entity is always a unique Group, matching the net result of
      # the previous prepare_source copy followed by place_cell_group cloning.
      class CellSpaceBatchTargetEntities
        def initialize(primal_group_resolver:)
          @primal_group_resolver = primal_group_resolver
        end

        def add_instance(definition, world_transformation)
          primal_group = resolve_primal_group
          local_transformation = self.class.primal_local_transformation(
            primal_group,
            world_transformation
          )

          created = primal_group.entities.add_instance(definition, local_transformation)
          raise ArgumentError, 'Could not create direct PrimalSpaceFeatures copy' unless created&.valid?

          created = created.to_group if created.respond_to?(:to_group)
          raise ArgumentError, 'Could not convert direct PrimalSpaceFeatures copy to Group' unless created&.valid?

          created.make_unique if created.respond_to?(:make_unique)
          created
        rescue StandardError
          created.erase! if created&.valid?
          raise
        end

        def self.primal_local_transformation(primal_group, world_transformation)
          primal_world = Utils::Transformation.root_transformation_in_model(primal_group)
          primal_world.inverse * world_transformation
        end

        private

        def resolve_primal_group
          primal_group = @primal_group_resolver.call
          unless primal_group&.valid? && primal_group.respond_to?(:entities)
            raise ArgumentError, 'IndoorGML_PrimalSpaceFeatures is not ready for direct batch copy'
          end

          primal_group
        end
      end

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
            target_entities = CellSpaceBatchTargetEntities.new(
              primal_group_resolver: proc { @primal_group }
            )

            BulkCellSpaceConversionService.new(
              model: model,
              jobs: jobs,
              fallback_target: fallback_target,
              target_entities: target_entities,
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
