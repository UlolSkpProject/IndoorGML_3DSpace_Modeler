# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Runtime-only visualization of overlapping XY circles and their
      # unobstructed lines of sight within each Room CellSpace.
      class ReferenceGraphDebugOverlayRenderer
        CIRCLE_OUTLINE_COLOR = Sketchup::Color.new(255, 255, 255, 110)
        EDGE_COLOR = Sketchup::Color.new(0, 0, 0)
        CIRCLE_SEGMENTS = 48

        def initialize(indoor_model:, transform_context:)
          @indoor_model = indoor_model
          @transform_context = transform_context
        end

        def draw_circles(view)
          return unless circle_diagnostics_enabled?

          each_graph do |graph|
            graph[:nodes].each do |node|
              radius = node[:radius].to_f
              next unless radius.positive? && radius.finite?

              circle = circle_in_root_local(node[:point], radius)
              next if circle.empty?

              rendered = render_points(circle)
              # Outline only: avoid creating and rendering a triangle fan for
              # every node on each overlay draw.
              view.drawing_color = CIRCLE_OUTLINE_COLOR
              view.line_width = 1
              view.line_stipple = '' if view.respond_to?(:line_stipple=)
              view.draw(GL_LINE_STRIP, rendered + [rendered.first])
            end
          end
        rescue StandardError => error
          log_debug_error(:circles, error)
        ensure
          view.line_width = 1 if view.respond_to?(:line_width=)
        end

        def draw_edges(view)
          view.drawing_color = EDGE_COLOR
          view.line_width = 1
          view.line_stipple = '' if view.respond_to?(:line_stipple=)
          each_graph do |graph|
            nodes = graph[:nodes]
            segments = graph[:edges].filter_map do |first, second|
              next unless nodes[first] && nodes[second]

              [nodes[first][:point], nodes[second][:point]]
            end
            next if segments.empty?

            model_points = render_points(segments.flatten(1))
            if top_down_view?(view)
              # Model-space lines can be depth-occluded by Room faces in the
              # Top view, even though the visibility edges are valid. Draw
              # only those views in screen space; retain the proven 3D
              # rendering path for oblique camera views.
              screen_points = model_points.map { |point| view.screen_coords(point) }
              view.draw2d(GL_LINES, screen_points)
            else
              view.draw(GL_LINES, model_points)
            end
          end
        rescue StandardError => error
          log_debug_error(:edges, error)
        ensure
          view.line_width = 1 if view.respond_to?(:line_width=)
        end

        def extent_points
          return [] unless circle_diagnostics_enabled?

          extents = []
          each_graph do |graph|
            graph[:nodes].each do |node|
              center = node[:point]
              radius = node[:radius].to_f
              next unless center && radius.finite?

              # Four transformed corners enclose an XY disk even under a
              # rotated root-group transform (max/min independently below).
              extents.concat(render_points([
                Geom::Point3d.new(center.x - radius, center.y - radius, center.z),
                Geom::Point3d.new(center.x - radius, center.y + radius, center.z),
                Geom::Point3d.new(center.x + radius, center.y - radius, center.z),
                Geom::Point3d.new(center.x + radius, center.y + radius, center.z)
              ]))
            end
          end
          return [] if extents.empty?

          xs = extents.map(&:x)
          ys = extents.map(&:y)
          zs = extents.map(&:z)
          [
            Geom::Point3d.new(xs.min, ys.min, zs.min),
            Geom::Point3d.new(xs.max, ys.max, zs.max)
          ]
        rescue StandardError
          []
        end

        private

        def circle_diagnostics_enabled?
          return true unless defined?(ReferenceGraphDebugMode)

          %i[before after].include?(ReferenceGraphDebugMode.mode)
        end

        def each_graph
          Array(@indoor_model.debug_reference_graphs).each do |graph|
            next unless graph && graph[:nodes] && graph[:edges]

            yield graph
          end
        end

        # World Top view and near-Top views suffer depth occlusion when the
        # graph's State-Z lines are behind the visible ceiling/floor.
        # This is deliberately not enabled for other camera directions.
        def top_down_view?(view)
          direction = view.camera.direction
          direction.z <= -0.98
        rescue StandardError
          false
        end

        def circle_in_root_local(center, radius)
          Array.new(CIRCLE_SEGMENTS) do |i|
            angle = 2.0 * Math::PI * i / CIRCLE_SEGMENTS
            Geom::Point3d.new(
              center.x + radius * Math.cos(angle),
              center.y + radius * Math.sin(angle),
              center.z
            )
          end
        end

        def render_points(points)
          if @transform_context.respond_to?(:overlay_render_points)
            @transform_context.overlay_render_points(points)
          else
            points.map { |point| render_point(point) }
          end
        end

        def render_point(point)
          @transform_context.overlay_render_point(point)
        end

        def log_debug_error(stage, error)
          @reported_errors ||= {}
          return if @reported_errors[stage]

          @reported_errors[stage] = true
          if defined?(IndoorCore::Logger)
            IndoorCore::Logger.puts(
              "[IndoorGML] Reference graph overlay #{stage} failed: " \
              "#{error.class}: #{error.message}"
            )
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end
