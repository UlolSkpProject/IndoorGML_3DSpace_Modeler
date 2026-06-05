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
              puts "[IndoorGML] Entity relocation failed: #{e.class}: #{e.message}"
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
            copy = target_entities.add_instance(entity.definition, transformation)
            copy = copy.to_group if entity.is_a?(Sketchup::Group) && copy.respond_to?(:to_group)
            copy.make_unique if entity.is_a?(Sketchup::Group) && copy.respond_to?(:make_unique)
            copy.name = entity.name if copy.respond_to?(:name=) && entity.respond_to?(:name)
            copy.material = entity.material if copy.respond_to?(:material=) && entity.respond_to?(:material)
            copy_indoor_attributes(entity, copy)
            copy
          end

          def relocation_transformation(entity, target_root_group)
            world_transformation = Utils::Transformation.entity_world_transformation(entity)
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
