# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class TransitionOverlayRenderer
        DUAL_TRANSITION_COLOR = Sketchup::Color.new(255, 255, 255, 220)
        TRANSITION_MIN_LINE_WIDTH_PIXELS = 2
        TRANSITION_LINE_WIDTH_PIXELS = 3
        TRANSITION_MAX_LINE_WIDTH_PIXELS = 4

        def initialize(curve_builder:)
          @curve_builder = curve_builder
        end

        def draw(view)
          view.line_width = overlay_transition_line_width if view.respond_to?(:line_width=)

          render_points = @curve_builder.transition_line_points
          return if render_points.empty?

          view.drawing_color = DUAL_TRANSITION_COLOR
          view.draw(GL_LINES, render_points)
        ensure
          view.line_width = 1 if view.respond_to?(:line_width=)
        end

        private

        def overlay_transition_line_width
          [
            [TRANSITION_LINE_WIDTH_PIXELS, TRANSITION_MIN_LINE_WIDTH_PIXELS].max,
            TRANSITION_MAX_LINE_WIDTH_PIXELS
          ].min
        end
      end
    end
  end
end
