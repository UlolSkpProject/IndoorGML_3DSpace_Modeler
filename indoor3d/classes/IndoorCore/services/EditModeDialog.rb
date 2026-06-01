# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditModeDialog
        def initialize(indoor_model)
          @indoor_model = indoor_model
          @dialog = nil
        end

        def show
          dialog.set_html(html)
          dialog.show
        end

        def close
          @dialog&.close if @dialog&.visible?
        rescue StandardError => e
          puts "[IndoorGML] Edit mode dialog close failed: #{e.class}: #{e.message}"
        end

        private

        def dialog
          @dialog ||= build_dialog
        end

        def build_dialog
          dialog = UI::HtmlDialog.new(
            dialog_title: 'IndoorGML Edit Mode',
            preferences_key: 'ULOL.Indoor3DGmlModeler.EditMode',
            scrollable: false,
            resizable: false,
            width: 280,
            height: 190,
            style: UI::HtmlDialog::STYLE_DIALOG
          )
          dialog.add_action_callback('setStateRadius') do |_context, radius_mm|
            @indoor_model.set_state_radius(radius_mm.to_f.mm)
          end
          dialog.add_action_callback('finishEditing') do |_context|
            @indoor_model.finish_editing()
          end
          dialog
        end

        def html
          radius_mm = (@indoor_model.state_radius.to_f / 1.mm).round
          <<~HTML
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <style>
                * { box-sizing: border-box; }
                body {
                  margin: 0;
                  padding: 16px;
                  font-family: Arial, sans-serif;
                  color: #18212b;
                  background: #f6f8fb;
                }
                .header {
                  font-size: 13px;
                  font-weight: 700;
                  letter-spacing: .04em;
                  color: #145291;
                  margin-bottom: 14px;
                }
                label {
                  display: flex;
                  justify-content: space-between;
                  align-items: baseline;
                  font-size: 12px;
                  font-weight: 700;
                  margin-bottom: 8px;
                }
                output {
                  font-weight: 400;
                  color: #4a5867;
                }
                input[type="range"] {
                  width: 100%;
                  margin: 0 0 18px;
                }
                button {
                  width: 100%;
                  height: 34px;
                  border: 0;
                  border-radius: 6px;
                  background: #145291;
                  color: white;
                  font-weight: 700;
                  cursor: pointer;
                }
                button:hover { background: #0f4275; }
              </style>
            </head>
            <body>
              <div class="header">EDIT MODE · PRIMAL SPACE</div>
              <label>
                <span>State radius</span>
                <output id="radiusValue">#{radius_mm} mm</output>
              </label>
              <input id="radius" type="range" min="500" max="5000" step="100" value="#{radius_mm}">
              <button id="finish" type="button">Finish</button>
              <script>
                const radius = document.getElementById('radius');
                const radiusValue = document.getElementById('radiusValue');
                radius.addEventListener('input', () => {
                  radiusValue.textContent = `${radius.value} mm`;
                });
                radius.addEventListener('change', () => {
                  sketchup.setStateRadius(Number(radius.value));
                });
                document.getElementById('finish').addEventListener('click', () => {
                  sketchup.finishEditing();
                });
              </script>
            </body>
            </html>
          HTML
        end
      end

    end
  end
end
