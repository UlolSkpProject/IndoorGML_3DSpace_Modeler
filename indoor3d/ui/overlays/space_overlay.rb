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

        # Batch variant for overlay rebuilds. The Primal -> model transform is
        # invariant during one rebuild, so resolve it once and reuse it for all
        # root-local points instead of querying the active context per State.
        def overlay_render_points(points)
          source_points = Array(points)
          transformation = Utils::Transformation.root_transformation_in_model(@indoor_model.primal_group)
          source_points.map do |point|
            point.is_a?(Geom::Point3d) ? point.transform(transformation) : point
          end
        rescue StandardError
          source_points.map { |point| overlay_render_point(point) }
        end

        def overlay_render_vector(vector)
          Utils::Transformation.root_local_vector_to_model(vector, @indoor_model.primal_group)
        rescue StandardError
          vector
        end

        # Captures the render transform once for a single overlay rebuild. This
        # snapshot is intentionally short-lived: callers must acquire a new one
        # for each rebuild so active-path / Primal transform changes are observed.
        def overlay_render_context_snapshot
          transformation = Utils::Transformation.root_transformation_in_model(@indoor_model.primal_group)
          {
            transformation: transformation,
            cache_key: [rounded_transformation_key(transformation)]
          }
        rescue StandardError
          nil
        end

        def overlay_render_point_from_snapshot(point, snapshot)
          transformation = snapshot && snapshot[:transformation]
          return overlay_render_point(point) unless transformation && point.is_a?(Geom::Point3d)

          point.transform(transformation)
        rescue StandardError
          overlay_render_point(point)
        end

        def overlay_render_vector_from_snapshot(vector, snapshot)
          transformation = snapshot && snapshot[:transformation]
          return overlay_render_vector(vector) unless transformation && vector.is_a?(Geom::Vector3d)

          transformed = vector.transform(transformation)
          transformed.normalize! if transformed.length > 0.001
          transformed
        rescue StandardError
          overlay_render_vector(vector)
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
