# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class SpaceOverlay < Sketchup::Overlay
        private

        def renderable_active_context?
          path = Sketchup.active_model&.active_path
          return true if path.nil?

          primal_group = @indoor_model.primal_group
          primal_group&.valid? && path.first == primal_group
        rescue StandardError
          false
        end

        def overlay_render_point(point)
          Utils::Transformation.root_local_point_to_model(point, @indoor_model.primal_group)
        rescue StandardError
          point
        end

        def overlay_render_vector(vector)
          Utils::Transformation.root_local_vector_to_model(vector, @indoor_model.primal_group)
        rescue StandardError
          vector
        end

        def overlay_render_context_cache_key
          [
            rounded_transformation_key(Utils::Transformation.root_transformation_in_model(@indoor_model.primal_group))
          ]
        rescue StandardError
          nil
        end

        def rounded_point_key(point)
          return nil unless point.is_a?(Geom::Point3d)

          [point.x.to_f.round(6), point.y.to_f.round(6), point.z.to_f.round(6)]
        end

        def rounded_vector_key(vector)
          return nil unless vector.is_a?(Geom::Vector3d)

          [vector.x.to_f.round(6), vector.y.to_f.round(6), vector.z.to_f.round(6)]
        end

        def rounded_transformation_key(transformation)
          return nil unless transformation.respond_to?(:to_a)

          transformation.to_a.map { |value| value.to_f.round(6) }
        end

        def camera_billboard_axes(view)
          up_axis = view.camera.up.clone
          up_axis.normalize!
          right_axis = view.camera.direction.cross(up_axis)
          right_axis.normalize!
          [right_axis, up_axis]
        end

        def overlay_state_root_local_point(state)
          group = state&.duality_cell&.valid_sketchup_group
          return Utils::Transformation.entity_origin_in_root_local(group, @indoor_model.primal_group) if group

          state.position
        rescue StandardError
          defined?(ORIGIN) ? ORIGIN : Geom::Point3d.new(0, 0, 0)
        end
      end
    end
  end
end
