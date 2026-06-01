# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditModeOverlay < Sketchup::Overlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.edit_mode_overlay'
        OVERLAY_NAME = 'IndoorGML Edit Mode'
        TITLE = 'EDIT MODE'
        CONTEXT_LABEL = 'PRIMAL SPACE'
        HINT_LABEL = 'CellSpace editing active'

        def initialize(indoor_model)
          @indoor_model = indoor_model
          super(OVERLAY_ID, OVERLAY_NAME, description: 'Shows when IndoorGML editing is active.')
        end

        def draw(view)
          begin
            return unless @indoor_model.editing?()

            draw_screen_border(view)
            draw_banner(view)
            draw_cell_space_outlines(view)
          rescue StandardError => e
            puts "[IndoorGML] Edit mode overlay draw failed: #{e.class}: #{e.message}"
          end
        end

        private

        def draw_banner(view)
          width = view.vpwidth()
          banner_height = 56
          draw_2d_quad(
            view,
            [
              [0, 0, 0],
              [width, 0, 0],
              [width, banner_height, 0],
              [0, banner_height, 0]
            ],
            Sketchup::Color.new(20, 82, 145, 210)
          )

          view.draw_text(
            Geom::Point3d.new(18, 13, 0),
            "#{TITLE} · #{CONTEXT_LABEL}",
            text_options(size: 18, bold: true, color: Sketchup::Color.new(255, 255, 255))
          )
          view.draw_text(
            Geom::Point3d.new(18, 34, 0),
            HINT_LABEL,
            text_options(size: 11, bold: false, color: Sketchup::Color.new(214, 231, 248))
          )
        end

        def draw_screen_border(view)
          width = view.vpwidth()
          height = view.vpheight()
          color = Sketchup::Color.new(20, 82, 145, 255)
          thickness = 4
          draw_2d_quad(view, [[0, 0, 0], [width, 0, 0], [width, thickness, 0], [0, thickness, 0]], color)
          draw_2d_quad(view, [[0, height - thickness, 0], [width, height - thickness, 0], [width, height, 0], [0, height, 0]], color)
          draw_2d_quad(view, [[0, 0, 0], [thickness, 0, 0], [thickness, height, 0], [0, height, 0]], color)
          draw_2d_quad(view, [[width - thickness, 0, 0], [width, 0, 0], [width, height, 0], [width - thickness, height, 0]], color)
        end

        def draw_cell_space_outlines(view)
          view.line_width = 3 if view.respond_to?(:line_width=)
          view.drawing_color = Sketchup::Color.new(20, 82, 145, 210)
          @indoor_model.cell_spaces.each do |cell_space|
            group = cell_space.sketchup_group
            next unless group&.valid?

            draw_bounds(view, group.bounds)
          end
        ensure
          view.line_width = 1 if view.respond_to?(:line_width=)
        end

        def draw_bounds(view, bounds)
          points = (0..7).map { |index| bounds.corner(index) }
          loops = [
            [0, 1, 3, 2],
            [4, 5, 7, 6],
            [0, 1, 5, 4],
            [2, 3, 7, 6],
            [0, 2, 6, 4],
            [1, 3, 7, 5]
          ]
          loops.each { |indices| view.draw(GL_LINE_LOOP, indices.map { |index| points[index] }) }
        end

        def draw_2d_quad(view, points, color)
          view.drawing_color = color
          view.draw2d(GL_QUADS, points.map { |point| Geom::Point3d.new(*point) })
        end

        def text_options(size:, bold:, color:)
          {
            size: size,
            bold: true,
            color: color
          }.merge(bold: bold)
        end
      end

    end
  end
end
