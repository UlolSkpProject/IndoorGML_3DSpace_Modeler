# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Transformation

        def self.entity_transformation_in_active_context(entity)
          Sketchup.active_model.edit_transform * entity.transformation
        end

        def self.entity_origin_in_root_local(entity, root_group)
          entity.transformation.origin
        end

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

          puts(message || default_child_warning(entity, root_group))
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
