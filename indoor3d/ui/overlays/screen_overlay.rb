# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ScreenOverlay < Sketchup::Overlay
        def getExtents
          Geom::BoundingBox.new
        end

        private

        def viewport_width(view)
          view.vpwidth()
        end

        def viewport_height(view)
          view.vpheight()
        end

        def draw_2d_quad(view, points, color)
          draw_2d_quads(view, [points], color)
        end

        def draw_2d_quads(view, quads, color)
          view.drawing_color = color
          points = quads.flatten(1).map { |point| Geom::Point3d.new(*point) }
          view.draw2d(GL_QUADS, points) unless points.empty?
        end

        def text_options(size:, bold:, color:)
          {
            size: size,
            bold: bold,
            color: color
          }
        end
      end
    end
  end
end
