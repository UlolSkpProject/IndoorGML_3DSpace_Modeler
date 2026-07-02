# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Transformation

        def self.entity_transformation_in_active_context(entity)
          Sketchup.active_model.edit_transform * entity.transformation
        end

        def self.entity_transformation_for_current_context(entity)
          return entity.transformation unless entity&.valid?

          active_entities = Sketchup.active_model&.active_entities
          if active_entities && active_entities.to_a.include?(entity)
            entity_transformation_in_active_context(entity)
          else
            entity_world_transformation(entity)
          end
        rescue StandardError
          entity&.transformation || Geom::Transformation.new
        end

        def self.entity_origin_in_root_local(entity, root_group)
          return entity.transformation.origin unless root_group&.valid?

          entity_transformation_in_root(entity, root_group).origin
        end

        def self.entity_world_transformation_under_root(entity, root_group)
          return entity.transformation unless entity&.valid?
          return entity.transformation unless root_group&.valid?

          active_path = Sketchup.active_model&.active_path
          if active_path&.include?(root_group)
            return Sketchup.active_model.edit_transform if active_path.last == entity
            return entity.transformation
          end

          root_transformation_in_model(root_group) * entity.transformation
        rescue StandardError
          entity&.transformation || Geom::Transformation.new
        end

        def self.entity_world_transformation(entity)
          return entity.transformation unless entity&.valid?

          model = Sketchup.active_model
          active_path = model&.active_path
          return model.edit_transform if active_path&.last == entity

          parent_transform = parent_instance_world_transformation(entity, active_path)
          return parent_transform * entity.transformation if parent_transform

          entity.transformation
        rescue StandardError
          entity&.transformation || Geom::Transformation.new
        end

        def self.entity_transformation_in_root(entity, root_group)
          return entity.transformation unless entity&.valid?
          return entity.transformation unless root_group&.valid?

          root_transformation_in_model(root_group).inverse * entity_world_transformation_under_root(entity, root_group)
        rescue StandardError
          entity&.transformation || Geom::Transformation.new
        end

        def self.root_transformation_in_model(root_group)
          return Geom::Transformation.new unless root_group&.valid?

          model = Sketchup.active_model
          active_path = model&.active_path
          return model.edit_transform if active_path&.last == root_group

          root_group.transformation
        rescue StandardError
          Geom::Transformation.new
        end

        def self.root_local_point_to_model(point, root_group)
          return point unless point.is_a?(Geom::Point3d)

          point.transform(root_transformation_in_model(root_group))
        end

        def self.root_local_vector_to_model(vector, root_group)
          return vector unless vector.is_a?(Geom::Vector3d)

          transformed = vector.transform(root_transformation_in_model(root_group))
          transformed.normalize! if transformed.length > 0.001
          transformed
        rescue StandardError
          vector
        end

        def self.parent_instance_world_transformation(entity, active_path = Sketchup.active_model&.active_path)
          parent = entity&.parent
          return nil unless parent.respond_to?(:instances)

          instances = parent.instances.select { |instance| instance&.valid? }
          return nil if instances.empty?

          parent_instance = active_path&.reverse_each&.find { |path_entity| instances.include?(path_entity) }
          return nil if parent_instance && active_path&.include?(parent_instance)

          parent_instance ||= instances.first
          return nil unless parent_instance&.valid?

          entity_world_transformation(parent_instance)
        rescue StandardError
          nil
        end
        private_class_method :parent_instance_world_transformation

        def self.move_entity_origin_in_root_local_to(entity, root_group, local_position)
          current_root_local_position = entity_origin_in_root_local(entity, root_group)
          vector = current_root_local_position.vector_to(local_position)
          return true if vector.length <= 0.001

          entity.transform!(Geom::Transformation.translation(vector))
          true
        end

        def self.editing_root_group?(root_group)
          active_path = Sketchup.active_model.active_path
          active_path&.include?(root_group)
        end

        def self.direct_child_of_root?(entity, root_group)
          return false unless entity&.valid? && valid_container?(root_group)

          entity.parent == parent_container_for(root_group)
        rescue StandardError
          false
        end

        def self.valid_container?(root_group)
          return false if root_group.nil?
          return root_group.valid? if root_group.respond_to?(:valid?)

          true
        end
        private_class_method :valid_container?

        def self.parent_container_for(root_group)
          return root_group.entities.parent if root_group.respond_to?(:entities) && !root_group.respond_to?(:definition)
          return root_group.definition if root_group.respond_to?(:definition)
          return root_group.parent if root_group.respond_to?(:parent)

          root_group
        end
        private_class_method :parent_container_for

        def self.ensure_direct_child_of_root!(entity, root_group, message = nil)
          return true if direct_child_of_root?(entity, root_group)

          IndoorCore::Logger.puts(message || default_child_warning(entity, root_group))
          false
        end

        def self.scaled?(transformation)
          values = transformation.to_a
          x_length = axis_length(values, 0)
          y_length = axis_length(values, 4)
          z_length = axis_length(values, 8)

          !same_float?(x_length, 1.0) || !same_float?(y_length, 1.0) || !same_float?(z_length, 1.0)
        end

        def self.same?(transformation1, transformation2)
          values1 = transformation1.to_a
          values2 = transformation2.to_a
          values1.each_index.all? { |index| same_float?(values1[index], values2[index]) }
        end

        def self.axis_length(values, start_index)
          Math.sqrt(
            (values[start_index]**2) +
            (values[start_index + 1]**2) +
            (values[start_index + 2]**2)
          )
        end
        private_class_method :axis_length

        def self.same_float?(value1, value2)
          (value1 - value2).abs <= 0.000001
        end
        private_class_method :same_float?

        def self.default_child_warning(entity, root_group)
          entity_name = entity.respond_to?(:name) ? entity.name : nil
          root_name = root_group.respond_to?(:name) ? root_group.name : nil
          "[IndoorGML] Coordinate warning: #{entity_name} is not a child of #{root_name}"
        end
        private_class_method :default_child_warning

      end
    end
  end
end
