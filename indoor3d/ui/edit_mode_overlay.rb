# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditModeOverlay < Sketchup::Overlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.edit_mode_overlay'
        OVERLAY_NAME = 'IndoorGML Edit Mode'
        TITLE = 'EDIT MODE - INDOOR GML'
        HINT_LABEL = 'Cellspace editing active'
        PRIMARY_COLOR = Sketchup::Color.new(22, 130, 82, 255)
        PRIMARY_TRANSLUCENT_COLOR = Sketchup::Color.new(22, 130, 82, 210)
        HINT_COLOR = Sketchup::Color.new(214, 245, 229)
        DUAL_STATE_COLOR = Sketchup::Color.new(35, 120, 255, 255)
        DUAL_TRANSITION_COLOR = Sketchup::Color.new(35, 120, 255, 125)
        CIRCLE_SEGMENTS = 16
        OVERLAY_RADIUS_SCALE = 1.1

        def initialize(indoor_model)
          @indoor_model = indoor_model
          super(OVERLAY_ID, OVERLAY_NAME, description: 'Shows when IndoorGML editing is active.')
        end

        def draw(view)
          begin
            return unless @indoor_model.editing?() || @indoor_model.dual_overlay_visible?()

            if @indoor_model.editing?()
              draw_screen_border(view)
              draw_banner(view)
              draw_cell_space_outlines(view)
            end
            draw_dual_space_overlay(view)
          rescue StandardError => e
            puts "[IndoorGML] Edit mode overlay draw failed: #{e.class}: #{e.message}"
          end
        end

        def getExtents
          begin
            bounds = Geom::BoundingBox.new
            add_cell_space_bounds(bounds)
            add_dual_overlay_bounds(bounds)
            bounds
          rescue StandardError => e
            puts "[IndoorGML] Edit mode overlay extents failed: #{e.class}: #{e.message}"
            Geom::BoundingBox.new
          end
        end

        private

        def add_cell_space_bounds(bounds)
          @indoor_model.cell_spaces.each do |cell_space|
            group = cell_space.valid_sketchup_group
            add_bounds(bounds, group.bounds) if group
          end
        end

        def add_bounds(target_bounds, source_bounds)
          (0..7).each { |index| target_bounds.add(source_bounds.corner(index)) }
        end

        def add_dual_overlay_bounds(bounds)
          @indoor_model.states.each do |state|
            next unless state&.valid?()

            point = overlay_state_point(state)
            radius = (state.radius || State.display_radius) * OVERLAY_RADIUS_SCALE
            bounds.add(
              Geom::Point3d.new(point.x - radius, point.y - radius, point.z - radius),
              Geom::Point3d.new(point.x + radius, point.y + radius, point.z + radius)
            )
          end
        end

        def draw_banner(view)
          w = view.vpwidth()
          h = 56
          draw_2d_quad(
            view,
            [
              [0, 0, 0],
              [w, 0, 0],
              [w, h, 0],
              [0, h, 0]
            ],
            PRIMARY_TRANSLUCENT_COLOR
          )

          view.draw_text(
            Geom::Point3d.new(18, 13, 0),
            TITLE,
            text_options(size: 18, bold: true, color: Sketchup::Color.new(255, 255, 255))
          )
          view.draw_text(
            Geom::Point3d.new(18, 34, 0),
            HINT_LABEL,
            text_options(size: 11, bold: false, color: HINT_COLOR)
          )
        end

        def draw_screen_border(view)
          w = view.vpwidth()
          h = view.vpheight()
          t = 4
          c = PRIMARY_COLOR
          draw_2d_quads(
            view,
            [
              [[0, 0, 0], [w, 0, 0], [w, t, 0], [0, t, 0]],
              [[0, h - t, 0], [w, h - t, 0], [w, h, 0], [0, h, 0]],
              [[0, 0, 0], [t, 0, 0], [t, h, 0], [0, h, 0]],
              [[w - t, 0, 0], [w, 0, 0], [w, h, 0], [w - t, h, 0]]
            ],
            c
          )
        end

        def draw_cell_space_outlines(view)
          begin
            view.line_width = 3 if view.respond_to?(:line_width=)
            view.drawing_color = PRIMARY_TRANSLUCENT_COLOR
            points = []
            @indoor_model.cell_spaces.each do |cell_space|
              group = cell_space.valid_sketchup_group
              next unless group

              points.concat(bounds_line_points(group.bounds))
            end
            view.draw(GL_LINES, points) unless points.empty?
          ensure
            view.line_width = 1 if view.respond_to?(:line_width=)
          end
        end

        def draw_dual_space_overlay(view)
          begin
            draw_overlay_transitions(view)
            draw_overlay_states(view)
          ensure
            view.line_width = 1 if view.respond_to?(:line_width=)
          end
        end

        def draw_overlay_states(view)
          view.drawing_color = DUAL_STATE_COLOR
          right_axis, up_axis = camera_billboard_axes(view)
          points = []
          @indoor_model.states.each do |state|
            next unless state&.valid?()

            center = overlay_state_point(state)
            radius = overlay_state_radius(view, center, state)
            points.concat(billboard_disk_triangle_points(center, right_axis, up_axis, radius))
          end
          view.draw(GL_TRIANGLES, points) unless points.empty?
        end

        def draw_overlay_transitions(view)
          view.drawing_color = DUAL_TRANSITION_COLOR
          view.line_width = overlay_transition_line_width if view.respond_to?(:line_width=)
          points = []
          @indoor_model.transitions.each do |transition|
            next unless transition&.valid?()
            next unless transition.state1&.valid?() && transition.state2&.valid?()

            point1 = overlay_state_point(transition.state1)
            point2 = overlay_state_point(transition.state2)
            next if point1.distance(point2) <= 0.001

            points << point1
            points << point2
          end
          view.draw(GL_LINES, points) unless points.empty?
        end

        def overlay_state_radius(view, center, state)
          model_radius = (state.radius || State.display_radius) * OVERLAY_RADIUS_SCALE
          clamp_overlay_radius(view, center, model_radius)
        end

        def overlay_transition_line_width
          [(@indoor_model.overlay_min_radius_pixels * 0.5).round, 1].max
        end

        def clamp_overlay_radius(view, center, model_radius, pixel_scale: 1.0)
          screen_min_radius = view.pixels_to_model(@indoor_model.overlay_min_radius_pixels * pixel_scale, center)
          screen_max_radius = view.pixels_to_model(@indoor_model.overlay_max_radius_pixels * pixel_scale, center)
          [[model_radius, screen_min_radius].max, screen_max_radius].min
        end

        def billboard_disk_triangle_points(center, right_axis, up_axis, radius)
          points = circle_points(center, right_axis, up_axis, radius)
          points.each_with_index.flat_map do |point, index|
            [center, point, points[(index + 1) % points.length]]
          end
        end

        def circle_points(center, axis1, axis2, radius)
          (0...CIRCLE_SEGMENTS).map do |index|
            angle = (2.0 * Math::PI * index) / CIRCLE_SEGMENTS
            Geom::Point3d.new(
              center.x + (axis1.x * Math.cos(angle) * radius) + (axis2.x * Math.sin(angle) * radius),
              center.y + (axis1.y * Math.cos(angle) * radius) + (axis2.y * Math.sin(angle) * radius),
              center.z + (axis1.z * Math.cos(angle) * radius) + (axis2.z * Math.sin(angle) * radius)
            )
          end
        end

        def camera_billboard_axes(view)
          up_axis = view.camera.up.clone
          up_axis.normalize!
          right_axis = view.camera.direction.cross(up_axis)
          right_axis.normalize!
          [right_axis, up_axis]
        end

        def overlay_state_point(state)
          cell_space = state.duality_cell
          group = cell_space&.valid_sketchup_group
          return group.bounds.center if group

          state.position
        rescue StandardError
          state.position
        end

        def bounds_line_points(bounds)
          points = (0..7).map { |index| bounds.corner(index) }
          edges = [
            [0, 1], [1, 3], [3, 2], [2, 0],
            [4, 5], [5, 7], [7, 6], [6, 4],
            [0, 4], [1, 5], [2, 6], [3, 7]
          ]
          edges.flat_map { |from, to| [points[from], points[to]] }
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
