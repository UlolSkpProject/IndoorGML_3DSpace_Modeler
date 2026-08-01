# frozen_string_literal: true

require_relative 'overlay_clock_patch'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressOverlayPrototype
        class ProgressOverlay
          TITLE_PIXEL_SIZE = 16
          DETAIL_PIXEL_SIZE = 13
          CRISP_PANEL_COLOR = Sketchup::Color.new(28, 32, 38, 248)
          CRISP_SECONDARY_TEXT_COLOR = Sketchup::Color.new(240, 244, 248, 255)

          def draw(view)
            snapshot = @state.snapshot
            return unless snapshot[:visible]

            available_width = viewport_width(view).to_f - (PANEL_MARGIN * 2)
            width = [PANEL_WIDTH.to_f, available_width].min.floor
            return if width <= 80

            # SketchUp 2025+ screen coordinates use logical pixels. Keep text
            # origins on whole logical pixels to avoid avoidable sub-pixel blur.
            x = ((viewport_width(view).to_f - width) / 2.0).round
            y = [
              viewport_height(view).to_f - PANEL_HEIGHT - PANEL_MARGIN,
              PANEL_MARGIN
            ].max.round

            draw_panel(view, x, y, width, snapshot)
          rescue StandardError => e
            puts "[THREADED PROGRESS OVERLAY] draw failed: #{e.class}: #{e.message}"
          end

          private

          def draw_panel(view, x, y, width, snapshot)
            draw_2d_quad(view, quad(x, y, width, PANEL_HEIGHT), CRISP_PANEL_COLOR)

            view.draw_text(
              screen_point(x + 14, y + 10),
              snapshot[:message].to_s,
              crisp_text_options(
                pixel_size: TITLE_PIXEL_SIZE,
                bold: true,
                color: PRIMARY_TEXT_COLOR
              )
            )

            view.draw_text(
              screen_point(x + 14, y + 34),
              detail_text(snapshot),
              crisp_text_options(
                pixel_size: DETAIL_PIXEL_SIZE,
                bold: false,
                color: CRISP_SECONDARY_TEXT_COLOR
              )
            )

            track_x = x + 14
            track_y = y + 61
            track_width = width - 28
            track_height = 8
            draw_2d_quad(view, quad(track_x, track_y, track_width, track_height), TRACK_COLOR)

            percent = normalized_percent(snapshot[:percent])
            fill_width = track_width * percent.fdiv(100.0)
            return unless fill_width.positive?

            draw_2d_quad(
              view,
              quad(track_x, track_y, fill_width, track_height),
              fill_color(snapshot)
            )
          end

          def crisp_text_options(pixel_size:, bold:, color:)
            {
              pixel_size: pixel_size.to_i,
              bold: bold == true,
              color: color
            }
          end

          def screen_point(x, y)
            Geom::Point3d.new(x.round, y.round, 0)
          end
        end
      end
    end
  end
end

puts '[THREADED PROGRESS OVERLAY TEXT PATCH] installed'
