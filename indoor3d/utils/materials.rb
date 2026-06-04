# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Materials

        DEFINITIONS = {
          state: ['Indoor3DGml_State', [0, 0, 255], 1.0],                           # DualSpace Node
          transition: ['Indoor3DGml_Transition', [0, 0, 255], 1.0],                 # DualSpace Link
          general_space: ['Indoor3DGml_GeneralSpace', [255, 0, 0], 0.3],
          transition_space: ['Indoor3DGml_TransitionSpace', [0, 128, 0], 0.8],
          connection_space: ['Indoor3DGml_ConnectionSpace', [145, 95, 210], 0.3],
          anchor_space: ['Indoor3DGml_AnchorSpace', [0, 200, 180], 0.8]
        }.freeze unless const_defined?(:DEFINITIONS, false)

        TEXTURE_DEFINITIONS = {
          general_space:    ['Indoor3DGml_GeneralSpace_Text',     'cellspace_room.png',   0.3],
          transition_space: ['Indoor3DGml_TransitionSpace_Text',  'cellspace_stair.png',  0.8],
          connection_space: ['Indoor3DGml_ConnectionSpace_Text',  'cellspace_door.png',   0.3]
        }.freeze unless const_defined?(:TEXTURE_DEFINITIONS, false)

        def self.state
          fetch(:state)
        end

        def self.transition
          fetch(:transition)
        end
        
        # text Material이 없는 경우를 위한 기본 값.
        def self.cell_space(cell_type)
          fetch(cell_space_type_keys()[cell_type] || :general_space)
        end

        def self.cell_space_text(cell_type)
          key = cell_space_type_keys()[cell_type]
          return nil unless TEXTURE_DEFINITIONS.key?(key)

          fetch_textured(key)
        end

        def self.ensure_all
          DEFINITIONS.each_key { |key| fetch(key) }
          TEXTURE_DEFINITIONS.each_key { |key| fetch_textured(key) }
        end

        def self.fetch(key)
          name, rgb, alpha = DEFINITIONS.fetch(key)
          material = Sketchup.active_model.materials[name] || Sketchup.active_model.materials.add(name)
          material.color = Sketchup::Color.new(*rgb)
          material.alpha = alpha if alpha && material.respond_to?(:alpha=)
          material
        end
        private_class_method :fetch

        def self.fetch_textured(key)
          name, texture_name, alpha = TEXTURE_DEFINITIONS.fetch(key)
          material = Sketchup.active_model.materials[name] || Sketchup.active_model.materials.add(name)
          material.texture = texture_path(texture_name)
          material.alpha = alpha if alpha && material.respond_to?(:alpha=)
          material
        end
        private_class_method :fetch_textured

        def self.texture_path(texture_name)
          File.expand_path("../assets/textures/#{texture_name}", __dir__)
        end
        private_class_method :texture_path

        def self.cell_space_type_keys
          cell_space_type = ::ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceType
          {
            cell_space_type::GENERAL => :general_space,
            cell_space_type::TRANSITION => :transition_space,
            cell_space_type::CONNECTION => :connection_space,
            cell_space_type::ANCHOR => :anchor_space
          }
        end
        private_class_method :cell_space_type_keys


        def self.generate_label_png(text, bg_color, text_color, width, height, output_path)
          dialog = UI::HtmlDialog.new({
            dialog_title: "PNG Generator",
            width: 200, height: 200,          # 1x1 피함
            style: UI::HtmlDialog::STYLE_UTILITY
          })
        
          html = <<~HTML
            <html><body style="margin:0">
            <canvas id="c" width="#{width}" height="#{height}"></canvas>
            <script>
              const c = document.getElementById('c');
              const ctx = c.getContext('2d');
              ctx.fillStyle = '#{bg_color}';
              ctx.fillRect(0, 0, #{width}, #{height});
              ctx.fillStyle = '#{text_color}';
              ctx.font = 'bold #{height / 3}px Arial';
              ctx.textAlign = 'center';
              ctx.textBaseline = 'middle';
              ctx.fillText('#{text}', #{width / 2}, #{height / 2});
              sketchup.png_ready(c.toDataURL('image/png'));
            </script>
            </body></html>
          HTML
        
          dialog.set_html(html)
        
          dialog.add_action_callback("png_ready") do |_, data_url|
            base64 = data_url.split(',', 2)[1]
            png_bytes = base64.unpack1('m')
            File.binwrite(output_path, png_bytes)
            dialog.close
          end
        
          dialog.show
        end
        private_class_method :generate_label_png
  
      end
    end
  end
end
