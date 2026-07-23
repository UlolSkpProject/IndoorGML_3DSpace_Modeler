# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ValidationErrorGeometryOverlay < SpaceOverlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.validation_error_geometry_overlay'
        OVERLAY_NAME = 'IndoorGML Validation Error Geometry Overlay'

        FACE_FILL_COLOR = Sketchup::Color.new(225, 44, 142, 112)
        FACE_EDGE_COLOR = Sketchup::Color.new(255, 116, 205, 255)
        OVERLAP_FILL_COLOR = Sketchup::Color.new(255, 82, 24, 156)
        OVERLAP_EDGE_COLOR = Sketchup::Color.new(255, 205, 56, 255)

        def initialize(indoor_model)
          @indoor_model = indoor_model
          @geometry = empty_geometry
          super(
            OVERLAY_ID,
            OVERLAY_NAME,
            description: 'Highlights validation error faces and CellSpace overlap volumes.'
          )
        end

        def set_geometry(geometry)
          @geometry = normalized_geometry(geometry)
          true
        end

        def clear
          @geometry = empty_geometry
          true
        end

        def draw(view)
          return unless draw_validation_geometry?

          draw_triangles(view, @geometry[:face_triangles], FACE_FILL_COLOR)
          draw_lines(view, @geometry[:face_edges], FACE_EDGE_COLOR, 4)
          draw_triangles(view, @geometry[:overlap_triangles], OVERLAP_FILL_COLOR)
          draw_lines(view, @geometry[:overlap_edges], OVERLAP_EDGE_COLOR, 3)
        rescue StandardError => e
          IndoorCore::Logger.puts(
            "[IndoorGML] Validation error geometry overlay draw failed: " \
            "#{e.class}: #{e.message}"
          )
        ensure
          view.line_width = 1 if view.respond_to?(:line_width=)
          view.line_stipple = '' if view.respond_to?(:line_stipple=)
        end

        def getExtents
          bounds = Geom::BoundingBox.new
          return bounds unless draw_validation_geometry?

          geometry_points.each { |point| bounds.add(point) }
          bounds
        rescue StandardError => e
          IndoorCore::Logger.puts(
            "[IndoorGML] Validation error geometry overlay extents failed: " \
            "#{e.class}: #{e.message}"
          )
          Geom::BoundingBox.new
        end

        private

        def draw_validation_geometry?
          return false unless renderable_active_context?
          return false unless @indoor_model.respond_to?(:validation_focus_active?)
          return false unless @indoor_model.validation_focus_active?

          !geometry_points.empty?
        end

        def draw_triangles(view, triangles, color)
          points = Array(triangles).flatten(1)
          return if points.empty?

          view.drawing_color = color
          view.draw(GL_TRIANGLES, points)
        end

        def draw_lines(view, points, color, width)
          render_points = Array(points)
          return if render_points.empty?

          view.drawing_color = color
          view.line_width = width if view.respond_to?(:line_width=)
          view.line_stipple = '' if view.respond_to?(:line_stipple=)
          view.draw(GL_LINES, render_points)
        end

        def geometry_points
          @geometry[:face_triangles].flatten(1) +
            @geometry[:face_edges] +
            @geometry[:overlap_triangles].flatten(1) +
            @geometry[:overlap_edges]
        end

        def normalized_geometry(geometry)
          source = geometry.is_a?(Hash) ? geometry : {}
          {
            face_triangles: Array(source[:face_triangles]),
            face_edges: Array(source[:face_edges]),
            overlap_triangles: Array(source[:overlap_triangles]),
            overlap_edges: Array(source[:overlap_edges])
          }
        end

        def empty_geometry
          {
            face_triangles: [],
            face_edges: [],
            overlap_triangles: [],
            overlap_edges: []
          }
        end
      end
    end
  end
end
