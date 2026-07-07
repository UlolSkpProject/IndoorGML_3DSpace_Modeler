# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Transformation

        def self.entity_transformation_in_active_context(entity)
          entity_world_transformation(entity)
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
          x_axis, y_axis, z_axis = axes(values)
          x_length = vector_length(x_axis)
          y_length = vector_length(y_axis)
          z_length = vector_length(z_axis)

          !same_float?(x_length, 1.0) ||
            !same_float?(y_length, 1.0) ||
            !same_float?(z_length, 1.0) ||
            !same_float?(dot(x_axis, y_axis), 0.0) ||
            !same_float?(dot(y_axis, z_axis), 0.0) ||
            !same_float?(dot(z_axis, x_axis), 0.0) ||
            determinant(x_axis, y_axis, z_axis) <= 0.000001
        end

        def self.unscaled(transformation)
          values = unscaled_values(transformation&.to_a)
          return nil unless values

          Geom::Transformation.new(values)
        end

        def self.scale_bake_transform(transformation)
          unscaled_transformation = unscaled(transformation)
          return nil unless unscaled_transformation

          unscaled_transformation.inverse * transformation
        end

        def self.unscaled_values(values)
          return nil unless values.is_a?(Array) && values.length == 16

          normalized = values.map(&:to_f)
          x_axis, y_axis, z_axis = orthonormal_axes(normalized)
          return nil unless x_axis && y_axis && z_axis

          assign_axis(normalized, 0, x_axis)
          assign_axis(normalized, 4, y_axis)
          assign_axis(normalized, 8, z_axis)
          normalized
        end

        def self.axes(values)
          [
            [values[0].to_f, values[1].to_f, values[2].to_f],
            [values[4].to_f, values[5].to_f, values[6].to_f],
            [values[8].to_f, values[9].to_f, values[10].to_f]
          ]
        end
        private_class_method :axes

        def self.orthonormal_axes(values)
          x_axis, y_axis = axes(values)
          x_axis = normalize_vector(x_axis)
          return nil unless x_axis

          y_axis = subtract(y_axis, multiply(x_axis, dot(y_axis, x_axis)))
          y_axis = normalize_vector(y_axis)
          return nil unless y_axis

          z_axis = cross(x_axis, y_axis)
          z_axis = normalize_vector(z_axis)
          return nil unless z_axis

          [x_axis, y_axis, z_axis]
        end
        private_class_method :orthonormal_axes

        def self.assign_axis(values, start_index, axis)
          values[start_index] = axis[0]
          values[start_index + 1] = axis[1]
          values[start_index + 2] = axis[2]
        end
        private_class_method :assign_axis

        def self.vector_length(vector)
          ::Math.sqrt(
            (vector[0]**2) +
            (vector[1]**2) +
            (vector[2]**2)
          )
        end
        private_class_method :vector_length

        def self.normalize_vector(vector)
          length = vector_length(vector)
          return nil if length <= 0.000001

          [
            vector[0] / length,
            vector[1] / length,
            vector[2] / length
          ]
        end
        private_class_method :normalize_vector

        def self.dot(vector1, vector2)
          (vector1[0] * vector2[0]) +
            (vector1[1] * vector2[1]) +
            (vector1[2] * vector2[2])
        end
        private_class_method :dot

        def self.cross(vector1, vector2)
          [
            (vector1[1] * vector2[2]) - (vector1[2] * vector2[1]),
            (vector1[2] * vector2[0]) - (vector1[0] * vector2[2]),
            (vector1[0] * vector2[1]) - (vector1[1] * vector2[0])
          ]
        end
        private_class_method :cross

        def self.subtract(vector1, vector2)
          [
            vector1[0] - vector2[0],
            vector1[1] - vector2[1],
            vector1[2] - vector2[2]
          ]
        end
        private_class_method :subtract

        def self.multiply(vector, scalar)
          [
            vector[0] * scalar,
            vector[1] * scalar,
            vector[2] * scalar
          ]
        end
        private_class_method :multiply

        def self.determinant(x_axis, y_axis, z_axis)
          dot(x_axis, cross(y_axis, z_axis))
        end
        private_class_method :determinant

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
