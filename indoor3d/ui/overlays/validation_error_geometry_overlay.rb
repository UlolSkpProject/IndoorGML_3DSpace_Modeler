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
          rebuild_geometry_cache
          super(
            OVERLAY_ID,
            OVERLAY_NAME,
            description: 'Highlights validation error faces and CellSpace overlap volumes.'
          )
        end

        def set_geometry(geometry)
          @geometry = normalized_geometry(geometry)
          rebuild_geometry_cache
          true
        end

        def clear
          @geometry = empty_geometry
          rebuild_geometry_cache
          true
        end

        def draw(view)
          return unless draw_validation_geometry?

          draw_triangles(view, @face_triangle_points, FACE_FILL_COLOR)
          draw_lines(view, @geometry[:face_edges], FACE_EDGE_COLOR, 4)
          draw_triangles(view, @overlap_triangle_points, OVERLAP_FILL_COLOR)
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

          @geometry_extent_points.each { |point| bounds.add(point) }
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

          !@geometry_points.empty?
        end

        def draw_triangles(view, points, color)
          render_points = Array(points)
          return if render_points.empty?

          view.drawing_color = color
          view.draw(GL_TRIANGLES, render_points)
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
          @geometry_points
        end

        def rebuild_geometry_cache
          @face_triangle_points = @geometry[:face_triangles].flatten(1)
          @overlap_triangle_points = @geometry[:overlap_triangles].flatten(1)
          @geometry_points =
            @face_triangle_points +
            @geometry[:face_edges] +
            @overlap_triangle_points +
            @geometry[:overlap_edges]
          @geometry_extent_points = geometry_extent_points(@geometry_points)
        end

        def geometry_extent_points(points)
          return [] if points.empty?

          bounds = Geom::BoundingBox.new
          points.each { |point| bounds.add(point) }
          return [] if bounds.respond_to?(:empty?) && bounds.empty?

          [bounds.min, bounds.max]
        rescue StandardError
          []
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
