# frozen_string_literal: true

require_relative 'overlay_clock_patch'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressOverlayPrototype
        module PixelAlignedProgressOverlay
          TITLE_PIXEL_SIZE = 14
          DETAIL_PIXEL_SIZE = 11

          def draw(view)
            snapshot = @state.snapshot
            return unless snapshot[:visible]

            width = [
              self.class::PANEL_WIDTH,
              viewport_width(view) - (self.class::PANEL_MARGIN * 2)
            ].min.round
            return if width <= 80

            x = ((viewport_width(view) - width) / 2.0).round
            y = [
              viewport_height(view) - self.class::PANEL_HEIGHT - self.class::PANEL_MARGIN,
              self.class::PANEL_MARGIN
            ].max.round

            draw_panel(view, x, y, width, snapshot)
          rescue StandardError => e
            puts "[THREADED PROGRESS OVERLAY] pixel-aligned draw failed: #{e.class}: #{e.message}"
          end

          private

          def draw_panel(view, x, y, width, snapshot)
            draw_2d_quad(
              view,
              pixel_quad(x, y, width, self.class::PANEL_HEIGHT),
              self.class::PANEL_COLOR
            )

            view.draw_text(
              screen_point(x + 14, y + 10),
              snapshot[:message].to_s,
              pixel_text_options(
                pixel_size: TITLE_PIXEL_SIZE,
                bold: true,
                color: self.class::PRIMARY_TEXT_COLOR
              )
            )

            view.draw_text(
              screen_point(x + 14, y + 32),
              detail_text(snapshot),
              pixel_text_options(
                pixel_size: DETAIL_PIXEL_SIZE,
                bold: false,
                color: self.class::SECONDARY_TEXT_COLOR
              )
            )

            track_x = x + 14
            track_y = y + 59
            track_width = width - 28
            track_height = 8
            draw_2d_quad(
              view,
              pixel_quad(track_x, track_y, track_width, track_height),
              self.class::TRACK_COLOR
            )

            percent = normalized_percent(snapshot[:percent])
            fill_width = (track_width * percent.fdiv(100.0)).round
            return unless fill_width.positive?

            draw_2d_quad(
              view,
              pixel_quad(track_x, track_y, fill_width, track_height),
              fill_color(snapshot)
            )
          end

          def screen_point(x, y)
            Geom::Point3d.new(x.round, y.round, 0)
          end

          def pixel_quad(x, y, width, height)
            left = x.round
            top = y.round
            right = (x + width).round
            bottom = (y + height).round
            [
              [left, top, 0],
              [right, top, 0],
              [right, bottom, 0],
              [left, bottom, 0]
            ]
          end

          def pixel_text_options(pixel_size:, bold:, color:)
            {
              pixel_size: pixel_size,
              bold: bold,
              color: color
            }
          end
        end

        ProgressOverlay.prepend(PixelAlignedProgressOverlay) unless
          ProgressOverlay.ancestors.include?(PixelAlignedProgressOverlay)
      end
    end
  end
end

Sketchup.active_model.active_view.invalidate if defined?(Sketchup)

puts '[THREADED PROGRESS OVERLAY TEXT CLARITY PATCH] installed'
