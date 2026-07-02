# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module EntityRelocation
          private

          def relocate_indoor_entity(entity, target_entities, target_root_group = nil, transparent: false)
            with_indoor_model_operation('IndoorGML Relocate Entity', transparent: transparent) do
              relocate_indoor_entity_without_operation(entity, target_entities, target_root_group)
            end
          end

          def relocate_indoor_entity_without_operation(entity, target_entities, target_root_group)
            begin
              return unless entity&.valid?
              return unless target_entities
              return if @relocating_entity

              if target_root_group&.valid? && Utils::Transformation.direct_child_of_root?(entity, target_root_group)
                lock_indoor_entity(entity) unless cell_space_entity?(entity)
                return entity
              end

              @relocating_entity = true
              copy = copy_entity_to_entities(entity, target_entities, target_root_group)
              unlock_indoor_entity(entity) unless cell_space_entity?(entity)
              entity.erase! if entity.valid?
              lock_indoor_entity(copy) unless cell_space_entity?(copy)
              copy
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Entity relocation failed: #{e.class}: #{e.message}"
              lock_indoor_entity(entity) unless cell_space_entity?(entity)
              nil
            ensure
              @relocating_entity = false
            end
          end

          def copy_entity_to_entities(entity, target_entities, target_root_group)
            unless entity.respond_to?(:definition) && entity.respond_to?(:transformation)
              raise ArgumentError, "Unsupported IndoorGML entity type: #{entity.class}"
            end

            transformation = relocation_transformation(entity, target_root_group)
            EntityCopyHelper.copy_instance(
              source: entity,
              target_entities: target_entities,
              transformation: transformation,
              convert_to_group: :source_group,
              make_unique: :source_group,
              copy_attributes: [:name, :material],
              attribute_copier: method(:copy_indoor_attributes)
            )
          end

          def relocation_transformation(entity, target_root_group)
            world_transformation = Utils::Transformation.entity_transformation_in_active_context(entity)
            return world_transformation unless target_root_group&.valid?

            target_root_group.transformation.inverse * world_transformation
          end

          def copy_indoor_attributes(source, target)
            @attribute_serializer.copy_indoor_attributes(source, target)
          end

          def cell_space_entity?(entity)
            indoor_feature(entity) == 'CellSpace'
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
