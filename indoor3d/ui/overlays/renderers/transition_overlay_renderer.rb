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

        # Partition cached segments once, then submit disjoint normal and
        # highlight batches. Different styles still require separate draw
        # calls, but a selected segment is never sent to the GPU twice.
        def draw(view, selected_cell_ids: nil, excluded_cell_ids: nil)
          batches = @curve_builder.transition_line_batches(
            selected_cell_ids: selected_cell_ids,
            excluded_cell_ids: excluded_cell_ids
          )
          draw_normal(view, batches[:normal])
          draw_highlight(view, batches[:highlight])
        ensure
          view.line_width = 1 if view.respond_to?(:line_width=)
        end

        private

        def draw_normal(view, render_points)
          return if render_points.empty?

          view.line_width = overlay_transition_line_width if view.respond_to?(:line_width=)
          view.drawing_color = DUAL_TRANSITION_COLOR
          view.draw(GL_LINES, render_points)
        end

        def draw_highlight(view, render_points)
          return if render_points.empty?

          view.line_width = SELECTED_TRANSITION_LINE_WIDTH_PIXELS if view.respond_to?(:line_width=)
          view.drawing_color = SELECTED_TRANSITION_COLOR
          view.draw(GL_LINES, render_points)
        end

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
