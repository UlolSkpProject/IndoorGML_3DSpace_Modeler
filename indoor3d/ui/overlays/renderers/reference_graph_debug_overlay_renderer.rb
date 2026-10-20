# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Runtime-only visualization of Native's completed Floor partitions.
      class ReferenceGraphDebugOverlayRenderer
        PARTITION_COLOR = Sketchup::Color.new(255, 120, 0, 230)
        EDGE_COLOR = Sketchup::Color.new(0, 0, 0)
        CLEAR_ADDED_EDGE_COLOR = Sketchup::Color.new(0, 125, 170)
        BLOCKED_ADDED_EDGE_COLOR = Sketchup::Color.new(210, 55, 40)

        def initialize(indoor_model:, transform_context:)
          @indoor_model = indoor_model
          @transform_context = transform_context
        end

        def draw_partitions(view)
          view.drawing_color = PARTITION_COLOR
          view.line_width = 2
          view.line_stipple = '' if view.respond_to?(:line_stipple=)

          each_partition do |partition|
            [partition[:outer], *Array(partition[:holes])].each do |ring|
              draw_ring(view, ring)
            end
          end
        rescue StandardError => error
          log_debug_error(:partitions, error)
        ensure
          view.line_width = 1 if view.respond_to?(:line_width=)
        end

        def draw_ring(view, ring)
          points = Array(ring)
          return if points.length < 3

          model_points = render_points(points + [points.first])
          if top_down_view?(view)
            screen_points = model_points.map { |point| view.screen_coords(point) }
            view.draw2d(GL_LINE_STRIP, screen_points)
          else
            view.draw(GL_LINE_STRIP, model_points)
          end
        end

        def draw_edges(view)
          view.line_width = 1
          view.line_stipple = '' if view.respond_to?(:line_stipple=)

          each_graph do |graph|
            nodes = graph[:nodes]
            base_count = graph.fetch(:original_edge_count, graph[:edges].length)
            draw_edge_group(view, nodes, graph[:edges].first(base_count), EDGE_COLOR, graph[:cell_id])
            additions = Array(graph[:added_edges])
            draw_edge_group(
              view, nodes,
              additions.select { |record| record[:classification] == :clear }.map { |record| record[:edge] },
              CLEAR_ADDED_EDGE_COLOR, graph[:cell_id]
            )
            draw_edge_group(
              view, nodes,
              additions.select { |record| record[:classification] == :blocked }.map { |record| record[:edge] },
              BLOCKED_ADDED_EDGE_COLOR, graph[:cell_id]
            )
          end
        rescue StandardError => error
          log_debug_error(:edges, error)
        ensure
          view.line_width = 1 if view.respond_to?(:line_width=)
        end

        def draw_edge_group(view, nodes, edges, color, cell_id)
          segments = Array(edges).filter_map do |first, second|
            next unless nodes[first] && nodes[second]

            [nodes[first][:point], nodes[second][:point]]
          end
          return if segments.empty?

          view.drawing_color = color
          model_points = render_points(segments.flatten(1), cell_id)
          if top_down_view?(view)
            screen_points = model_points.map { |point| view.screen_coords(point) }
            view.draw2d(GL_LINES, screen_points)
          else
            view.draw(GL_LINES, model_points)
          end
        end

        def extent_points
          points = []
          each_partition do |partition|
            points.concat(Array(partition[:outer]))
            Array(partition[:holes]).each { |ring| points.concat(Array(ring)) }
          end
          extents = render_points(points)
          return [] if extents.empty?

          coordinates = %i[x y z].map do |axis|
            values = extents.map { |point| point.public_send(axis) }
            [values.min, values.max]
          end
          [
            Geom::Point3d.new(coordinates[0][0], coordinates[1][0], coordinates[2][0]),
            Geom::Point3d.new(coordinates[0][1], coordinates[1][1], coordinates[2][1])
          ]
        rescue StandardError
          []
        end

        private

        def each_partition
          Array(@indoor_model.debug_floor_partitions).each do |partition|
            next unless partition && Array(partition[:outer]).length >= 3

            yield partition
          end
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

        def render_points(points, cell_id = nil)
          if cell_id
            @transform_context.overlay_cell_reference_points(points, cell_id)
          elsif @transform_context.respond_to?(:overlay_render_points)
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
