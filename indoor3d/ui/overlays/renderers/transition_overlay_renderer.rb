# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class TransitionOverlayRenderer
        DUAL_TRANSITION_COLOR = Sketchup::Color.new(255, 255, 255, 125)
        # Purple sampled from the supplied dual-graph reference image.
        SELECTED_TRANSITION_COLOR = Sketchup::Color.new(48, 0, 137)
        SELECTED_TRANSITION_LINE_WIDTH_PIXELS = 6
        TRANSITION_MIN_LINE_WIDTH_PIXELS = 2
        TRANSITION_LINE_WIDTH_PIXELS = 3
        TRANSITION_MAX_LINE_WIDTH_PIXELS = 4

        def initialize(curve_builder:)
          @curve_builder = curve_builder
        end

        def draw(view, excluded_cell_ids: nil)
          view.line_width = overlay_transition_line_width if view.respond_to?(:line_width=)

          render_points = @curve_builder.transition_line_points(excluded_cell_ids: excluded_cell_ids)
          return if render_points.empty?

          view.drawing_color = DUAL_TRANSITION_COLOR
          view.draw(GL_LINES, render_points)
        ensure
          view.line_width = 1 if view.respond_to?(:line_width=)
        end

        # Draw only selected cells' visible Transition segments, after the
        # normal pass. Do not invalidate or mutate the underlying curves.
        def draw_highlight(view, selected_cell_ids:, excluded_cell_ids: nil)
          return if selected_cell_ids.nil? || selected_cell_ids.empty?

          render_points = @curve_builder.selected_transition_line_points(
            selected_cell_ids: selected_cell_ids,
            excluded_cell_ids: excluded_cell_ids
          )
          return if render_points.empty?

          view.line_width = SELECTED_TRANSITION_LINE_WIDTH_PIXELS if view.respond_to?(:line_width=)
          view.drawing_color = SELECTED_TRANSITION_COLOR
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
