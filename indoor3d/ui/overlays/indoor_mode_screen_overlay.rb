# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModeScreenOverlay < ScreenOverlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.indoor_mode_screen_overlay'
        OVERLAY_NAME = 'IndoorGML Mode UI'
        TITLE = 'EDIT MODE - INDOOR GML'
        FIX_TITLE = 'FIX MODE - INDOOR GML'
        HINT_LABEL = 'Cellspace editing active'
        FIX_HINT_LABEL = 'Validation error fixing active'
        PRIMARY_COLOR = Sketchup::Color.new(22, 130, 82, 255)
        PRIMARY_TRANSLUCENT_COLOR = Sketchup::Color.new(22, 130, 82, 210)
        FIX_PRIMARY_COLOR = Sketchup::Color.new(185, 28, 28, 255)
        FIX_PRIMARY_TRANSLUCENT_COLOR = Sketchup::Color.new(185, 28, 28, 210)
        HINT_COLOR = Sketchup::Color.new(214, 245, 229)
        FIX_HINT_COLOR = Sketchup::Color.new(254, 226, 226)

        def initialize(indoor_model)
          @indoor_model = indoor_model
          super(OVERLAY_ID, OVERLAY_NAME, description: 'Shows when IndoorGML editing is active.')
        end

        def draw(view)
          return unless @indoor_model.editing?()

          draw_screen_border(view)
          draw_banner(view)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Mode screen overlay draw failed: #{e.class}: #{e.message}"
        end

        private

        def draw_banner(view)
          w = viewport_width(view)
          h = 56
          draw_2d_quad(
            view,
            [
              [0, 0, 0],
              [w, 0, 0],
              [w, h, 0],
              [0, h, 0]
            ],
            screen_overlay_translucent_color
          )

          view.draw_text(
            Geom::Point3d.new(18, 13, 0),
            screen_overlay_title,
            text_options(size: 18, bold: true, color: Sketchup::Color.new(255, 255, 255))
          )
          view.draw_text(
            Geom::Point3d.new(18, 34, 0),
            screen_overlay_hint,
            text_options(size: 11, bold: false, color: screen_overlay_hint_color)
          )
        end

        def draw_screen_border(view)
          w = viewport_width(view)
          h = viewport_height(view)
          t = 4
          c = screen_overlay_color
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

        def validation_focus_active?
          @indoor_model.respond_to?(:validation_focus_active?) && @indoor_model.validation_focus_active?
        end

        def screen_overlay_color
          validation_focus_active? ? FIX_PRIMARY_COLOR : PRIMARY_COLOR
        end

        def screen_overlay_translucent_color
          validation_focus_active? ? FIX_PRIMARY_TRANSLUCENT_COLOR : PRIMARY_TRANSLUCENT_COLOR
        end

        def screen_overlay_title
          validation_focus_active? ? FIX_TITLE : TITLE
        end

        def screen_overlay_hint
          validation_focus_active? ? FIX_HINT_LABEL : HINT_LABEL
        end

        def screen_overlay_hint_color
          validation_focus_active? ? FIX_HINT_COLOR : HINT_COLOR
        end
      end
    end
  end
end
