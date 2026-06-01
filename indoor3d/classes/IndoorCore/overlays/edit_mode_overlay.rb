# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditModeOverlay < Sketchup::Overlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.edit_mode_overlay'
        OVERLAY_NAME = 'IndoorGML Edit Mode'
        LABEL = 'IndoorGML Edit Mode'

        def initialize(indoor_model)
          @indoor_model = indoor_model
          super(OVERLAY_ID, OVERLAY_NAME, description: 'Shows when IndoorGML editing is active.')
        end

        def draw(view)
          begin
            unless @indoor_model.editing?()
              warn "[IndoorGML] is Not Editing"
              return
            end
            puts "OVERLAY"
            point = Geom::Point3d.new(view.vpwidth() * 0.5, 24, 0)
            view.draw_text(point, LABEL, text_options())
          rescue StandardError => e
            puts "[IndoorGML] Edit mode overlay draw failed: #{e.class}: #{e.message}"
          end
        end

        private

        def text_options
          options = {
            size: 80,
            bold: true,
            color: Sketchup::Color.new(30, 115, 190)
          }
          options[:align] = TextAlignCenter if defined?(TextAlignCenter)
          options
        end
      end

    end
  end
end
