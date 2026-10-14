# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Temporary visualization for Native CellSpace reference points.
      class ReferencePointDebugOverlayRenderer
        REFERENCE_POINT_COLOR = Sketchup::Color.new(255, 140, 0)
        REFERENCE_POINT_SIZE_PIXELS = 8
        # Deliberately different from StateOverlayRenderer::STATE_POINT_STYLE (7).
        REFERENCE_POINT_STYLE = 2

        def initialize(indoor_model:, transform_context:)
          @indoor_model = indoor_model
          @transform_context = transform_context
        end

        def draw(view)
          points = render_points
          return if points.empty?

          view.draw_points(
            points,
            REFERENCE_POINT_SIZE_PIXELS,
            REFERENCE_POINT_STYLE,
            REFERENCE_POINT_COLOR
          )
        end

        def extent_points
          points = render_points
          return [] if points.empty?

          xs = points.map(&:x)
          ys = points.map(&:y)
          zs = points.map(&:z)
          [
            Geom::Point3d.new(xs.min, ys.min, zs.min),
            Geom::Point3d.new(xs.max, ys.max, zs.max)
          ]
        end

        private

        def render_points
          root_local_points = Array(@indoor_model.debug_reference_points)
          return [] if root_local_points.empty?

          if @transform_context.respond_to?(:overlay_render_points)
            @transform_context.overlay_render_points(root_local_points)
          else
            root_local_points.map { |point| @transform_context.overlay_render_point(point) }
          end
        rescue StandardError
          []
        end
      end
    end
  end
end
