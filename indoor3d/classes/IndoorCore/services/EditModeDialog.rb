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

        def update_selection(snapshot)
          return unless @dialog&.visible?

          @dialog.execute_script(selection_script(snapshot))
        rescue StandardError => e
          puts "[IndoorGML] Edit mode dialog selection update failed: #{e.class}: #{e.message}"
        end

        def close
          @dialog&.close if @dialog&.visible?
          @dialog = nil
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
            scrollable: true,
            resizable: false,
            width: 280,
            height: 400,
            style: UI::HtmlDialog::STYLE_DIALOG
          )
          dialog.add_action_callback('setStateRadius') do |_context, radius_mm|
            puts "[IndoorGML] EditModeDialog#setStateRadius radius_mm=#{radius_mm}"
            UI.start_timer(0, false) do
              @indoor_model.set_state_radius(radius_mm.to_f.mm)
            end
          end
          dialog.add_action_callback('setOverlayMinRadius') do |_context, radius_pixels|
            puts "[IndoorGML] EditModeDialog#setOverlayMinRadius radius_pixels=#{radius_pixels}"
            UI.start_timer(0, false) do
              @indoor_model.set_overlay_min_radius_pixels(radius_pixels)
            end
          end
          dialog.add_action_callback('setOverlayRadiusRange') do |_context, min_radius_pixels, max_radius_pixels|
            puts "[IndoorGML] EditModeDialog#setOverlayRadiusRange min=#{min_radius_pixels} max=#{max_radius_pixels}"
            UI.start_timer(0, false) do
              @indoor_model.set_overlay_radius_pixel_range(min_radius_pixels, max_radius_pixels)
            end
          end
          dialog.add_action_callback('setSelectedCellSpaceType') do |_context, cell_type_label|
            puts "[IndoorGML] EditModeDialog#setSelectedCellSpaceType type=#{cell_type_label}"
            UI.start_timer(0, false) do
              @indoor_model.set_selected_cell_space_type(cell_type_label)
            end
          end
          dialog.add_action_callback('finishEditing') do |_context|
            puts '[IndoorGML] EditModeDialog#finishEditing'
            UI.start_timer(0, false) do
              @indoor_model.finish_editing()
            end
          end
          dialog.add_action_callback('clearAllIndoorGmlElements') do |_context|
            puts '[IndoorGML] EditModeDialog#clearAllIndoorGmlElements'
            UI.start_timer(0, false) do
              @indoor_model.clear_all_indoor_gml_elements()
            end
          end
          dialog.set_on_closed { @dialog = nil } if dialog.respond_to?(:set_on_closed)
          dialog
        end

        def html
          radius_mm = (@indoor_model.state_radius.to_f / 1.mm).round
          overlay_min_radius = @indoor_model.overlay_min_radius_pixels.round
          overlay_max_radius = @indoor_model.overlay_max_radius_pixels.round
          cell_type_options = CellSpaceType::LABELS.values.map do |label|
            "<option value=\"#{escape_html(label)}\">#{escape_html(label)}</option>"
          end.join
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
                .panel {
                  border-top: 1px solid #d8e0e8;
                  border-bottom: 1px solid #d8e0e8;
                  padding: 12px 0;
                  margin: 0 0 14px;
                }
                .row {
                  display: flex;
                  justify-content: space-between;
                  gap: 12px;
                  font-size: 12px;
                  margin-bottom: 6px;
                }
                .row span:first-child {
                  color: #667484;
                }
                .row span:last-child {
                  min-width: 0;
                  overflow: hidden;
                  text-overflow: ellipsis;
                  white-space: nowrap;
                }
                select {
                  width: 100%;
                  height: 30px;
                  margin-top: 6px;
                }
                input[type="range"] {
                  width: 100%;
                  margin: 0 0 14px;
                }
                .range-row {
                  display: grid;
                  grid-template-columns: 1fr 1fr;
                  gap: 8px;
                  margin-bottom: 14px;
                }
                .range-row input[type="range"] {
                  margin-bottom: 0;
                }
                button {
                  width: 100%;
                  height: 34px;
                  margin-top: 8px;
                  border: 0;
                  border-radius: 6px;
                  background: #145291;
                  color: white;
                  font-weight: 700;
                  cursor: pointer;
                }
                button:hover { background: #0f4275; }
                button.danger {
                  background: #a43838;
                }
                button.danger:hover {
                  background: #842d2d;
                }
              </style>
            </head>
            <body>
              <div class="header">EDIT MODE · PRIMAL SPACE</div>
              <div class="panel">
                <div class="row"><span>Selected</span><span id="selectedFeature">None</span></div>
                <div class="row"><span>ID</span><span id="selectedId">-</span></div>
                <div class="row"><span>Name</span><span id="selectedName">-</span></div>
                <select id="selectedType" disabled>
                  #{cell_type_options}
                </select>
              </div>
              <label>
                <span>State radius</span>
                <output id="radiusValue">#{radius_mm} mm</output>
              </label>
              <input id="radius" type="range" min="500" max="5000" step="100" value="#{radius_mm}">
              <label>
                <span>Overlay radius range</span>
                <output id="overlayRadiusValue">#{overlay_min_radius}-#{overlay_max_radius} px</output>
              </label>
              <div class="range-row">
                <input id="overlayMinRadius" type="range" min="4" max="128" step="1" value="#{overlay_min_radius}">
                <input id="overlayMaxRadius" type="range" min="4" max="128" step="1" value="#{overlay_max_radius}">
              </div>
              <button id="finish" type="button">Finish</button>
              <button id="clearAll" class="danger" type="button">Clear All IndoorGML Elements</button>
              <script>
                var radius = document.getElementById('radius');
                var radiusValue = document.getElementById('radiusValue');
                var overlayMinRadius = document.getElementById('overlayMinRadius');
                var overlayMaxRadius = document.getElementById('overlayMaxRadius');
                var overlayRadiusValue = document.getElementById('overlayRadiusValue');
                var selectedFeature = document.getElementById('selectedFeature');
                var selectedId = document.getElementById('selectedId');
                var selectedName = document.getElementById('selectedName');
                var selectedType = document.getElementById('selectedType');
                var suppressTypeChange = false;
                function updateSelectedCellSpace(snapshot) {
                  suppressTypeChange = true;
                  if (!snapshot || !snapshot.id) {
                    selectedFeature.textContent = 'None';
                    selectedId.textContent = '-';
                    selectedName.textContent = '-';
                    selectedType.disabled = true;
                    selectedType.value = 'GeneralSpace';
                  } else {
                    selectedFeature.textContent = snapshot.feature || 'CellSpace';
                    selectedId.textContent = snapshot.id || '-';
                    selectedName.textContent = snapshot.name || '-';
                    selectedType.disabled = false;
                    selectedType.value = snapshot.cellType || 'GeneralSpace';
                  }
                  suppressTypeChange = false;
                }
                function updateOverlayRadiusRange() {
                  var minRadius = Number(overlayMinRadius.value);
                  var maxRadius = Number(overlayMaxRadius.value);
                  if (minRadius > maxRadius) {
                    if (document.activeElement === overlayMinRadius) {
                      overlayMaxRadius.value = minRadius;
                      maxRadius = minRadius;
                    } else {
                      overlayMinRadius.value = maxRadius;
                      minRadius = maxRadius;
                    }
                  }
                  overlayRadiusValue.textContent = `${minRadius}-${maxRadius} px`;
                  sketchup.setOverlayRadiusRange(minRadius, maxRadius);
                }
                radius.addEventListener('input', function () {
                  radiusValue.textContent = `${radius.value} mm`;
                });
                radius.addEventListener('change', function () {
                  sketchup.setStateRadius(Number(radius.value));
                });
                overlayMinRadius.addEventListener('input', updateOverlayRadiusRange);
                overlayMaxRadius.addEventListener('input', updateOverlayRadiusRange);
                selectedType.addEventListener('change', function () {
                  if (!suppressTypeChange) {
                    sketchup.setSelectedCellSpaceType(selectedType.value);
                  }
                });
                document.getElementById('finish').addEventListener('click', function () {
                  sketchup.finishEditing();
                });
                document.getElementById('clearAll').addEventListener('click', function () {
                  sketchup.clearAllIndoorGmlElements();
                });
              </script>
            </body>
            </html>
          HTML
        end

        def selection_script(snapshot)
          if snapshot.nil?
            'updateSelectedCellSpace(null);'
          else
            <<~JS
              updateSelectedCellSpace({
                feature: #{js_string(snapshot[:feature])},
                id: #{js_string(snapshot[:id])},
                name: #{js_string(snapshot[:name])},
                cellType: #{js_string(snapshot[:cell_type])}
              });
            JS
          end
        end

        def js_string(value)
          value.to_s.inspect
        end

        def escape_html(value)
          value.to_s
               .gsub('&', '&amp;')
               .gsub('<', '&lt;')
               .gsub('>', '&gt;')
               .gsub('"', '&quot;')
        end
      end

    end
  end
end
