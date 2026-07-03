# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module PrimalNormalization
          private

          def normalize_primal_children_for_finish
            return unless @primal_group&.valid?

            with_indoor_model_operation('IndoorGML Normalize Primal Children On Finish', transparent: true) do
              begin
                @relocating_entity = true
                raw_entities = []
                @primal_group.entities.to_a.each do |entity|
                  normalize_primal_child_for_finish(entity, raw_entities)
                end
                move_raw_primal_entities_to_root(raw_entities)
              ensure
                @relocating_entity = false
              end
              # refresh_runtime_data
              Sketchup.active_model.active_view.invalidate if Sketchup.active_model&.active_view
            end
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Primal children finish normalize failed: #{e.class}: #{e.message}"
          end

          def normalize_primal_child_for_finish(entity, raw_entities)
            return unless entity&.valid?
            return if space_features_origin_point?(entity)
            return if indoor_feature(entity) == 'CellSpace'
            return if auto_convert_tagged_primal_entity(entity)

            if entity.respond_to?(:definition) && entity.respond_to?(:transformation)
              normalize_primal_container_without_operation(entity)
            else
              raw_entities << entity
            end
          end

          def normalize_primal_container_without_operation(container)
            auto_convert_direct_tagged_children(container)
            nested_cell_space_entities(container).each do |entry|
              copy_nested_cell_space_to_primal(entry[:entity], entry[:transformation])
            end
            cleanup_or_move_primal_container(container)
          end

          def nested_cell_space_entities(container, parent_transformation = nil)
            return [] unless container&.valid?
            return [] unless container.respond_to?(:definition) && container.respond_to?(:transformation)

            accumulated = (parent_transformation || Geom::Transformation.new) * container.transformation
            container.definition.entities.to_a.flat_map do |child|
              next [] unless child&.valid?

              if indoor_feature(child) == 'CellSpace'
                [{ entity: child, transformation: accumulated * child.transformation }]
              elsif child.respond_to?(:definition) && child.respond_to?(:transformation)
                nested_cell_space_entities(child, accumulated)
              else
                []
              end
            end
          end

          def copy_nested_cell_space_to_primal(entity, local_transformation)
            copy = @primal_group.entities.add_instance(entity.definition, local_transformation)
            copy = copy.to_group if entity.is_a?(Sketchup::Group) && copy.respond_to?(:to_group)
            copy.make_unique if entity.is_a?(Sketchup::Group) && copy.respond_to?(:make_unique)
            copy.name = entity.name if copy.respond_to?(:name=) && entity.respond_to?(:name)
            copy.material = entity.material if copy.respond_to?(:material=) && entity.respond_to?(:material)
            copy_indoor_attributes(entity, copy)
            entity.erase! if entity.valid?
            copy
          end

          def cleanup_or_move_primal_container(container)
            return unless container&.valid?

            if container.respond_to?(:definition) && container.definition.entities.to_a.empty?
              container.erase!
            else
              move_remaining_primal_container_to_root(container)
            end
          end

          def move_remaining_primal_container_to_root(container)
            return unless container&.valid?
            return unless container.respond_to?(:definition) && container.respond_to?(:transformation)
            return unless primal_direct_container?(container)

            model = Sketchup.active_model
            copy = model.entities.add_instance(container.definition, @primal_group.transformation * container.transformation)
            copy = copy.to_group if container.is_a?(Sketchup::Group) && copy.respond_to?(:to_group)
            copy.make_unique if container.is_a?(Sketchup::Group) && copy.respond_to?(:make_unique)
            copy.name = container.name if copy.respond_to?(:name=) && container.respond_to?(:name)
            copy.material = container.material if copy.respond_to?(:material=) && container.respond_to?(:material)
            copy.layer = container.layer if copy.respond_to?(:layer=) && container.respond_to?(:layer)
            copy.visible = container.visible? if copy.respond_to?(:visible=) && container.respond_to?(:visible?)
            container.erase! if container.valid?
            copy
          end

          def move_raw_primal_entities_to_root(entities)
            raw_entities = Array(entities).select { |entity| entity&.valid? }
            return if raw_entities.empty?
            return unless @primal_group&.valid?

            wrapper = @primal_group.entities.add_group(raw_entities)
            return unless wrapper&.valid?
            if wrapper.entities.to_a.empty?
              wrapper.erase!
              return
            end

            wrapper.name = 'Unconverted Geometry' if wrapper.respond_to?(:name=)
            move_remaining_primal_container_to_root(wrapper)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Raw primal entities relocate failed: #{e.class}: #{e.message}"
            nil
          end

          def space_features_origin_point?(entity)
            return false unless entity.is_a?(Sketchup::ConstructionPoint)

            entity.position.distance(ORIGIN) <= 0.001
          rescue StandardError
            false
          end

          def primal_direct_container?(entity)
            return false unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            return false unless @primal_group&.valid?

            Utils::Transformation.direct_child_of_root?(entity, @primal_group)
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
