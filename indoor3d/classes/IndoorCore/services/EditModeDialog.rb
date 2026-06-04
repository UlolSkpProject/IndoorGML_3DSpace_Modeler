# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditModeDialog
        DIALOG_WIDTH = 280
        INITIAL_DIALOG_HEIGHT = 260
        MIN_DIALOG_HEIGHT = 280
        MAX_DIALOG_HEIGHT = 620
        CONTENT_PADDING_HEIGHT = 24
        DIALOG_WINDOW_CHROME_HEIGHT = 96

        def initialize(indoor_model)
          @indoor_model = indoor_model
          @dialog = nil
        end

        def show
          dialog.set_html(html)
          dialog.show
        end

        def update_selection(snapshot)
          begin
            return unless @dialog&.visible?

            @dialog.execute_script(selection_script(snapshot))
          rescue StandardError => e
            puts "[IndoorGML] Edit mode dialog selection update failed: #{e.class}: #{e.message}"
          end
        end

        def close
          begin
            @dialog&.close if @dialog&.visible?
            @dialog = nil
          rescue StandardError => e
            puts "[IndoorGML] Edit mode dialog close failed: #{e.class}: #{e.message}"
          end
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
            width: DIALOG_WIDTH,
            height: INITIAL_DIALOG_HEIGHT,
            style: UI::HtmlDialog::STYLE_DIALOG
          )
          dialog.add_action_callback('fitContentHeight') do |_context, content_height|
            fit_content_height(content_height)
          end
          dialog.add_action_callback('setOverlayMinRadius') do |_context, radius_pixels|
            UI.start_timer(0, false) do
              @indoor_model.set_overlay_min_radius_pixels(radius_pixels)
            end
          end
          dialog.add_action_callback('setOverlayRadiusRange') do |_context, min_radius_pixels, max_radius_pixels|
            UI.start_timer(0, false) do
              @indoor_model.set_overlay_radius_pixel_range(min_radius_pixels, max_radius_pixels)
            end
          end
          dialog.add_action_callback('setSelectedCellSpaceClassification') do |_context, selection_value|
            puts "[IndoorGML] EditModeDialog#setSelectedCellSpaceClassification value=#{selection_value}"
            UI.start_timer(0, false) do
              @indoor_model.set_selected_cell_space_classification(selection_value)
            end
          end
          dialog.add_action_callback('editSelectedCellSpace') do |_context|
            puts '[IndoorGML] EditModeDialog#editSelectedCellSpace'
            UI.start_timer(0, false) do
              @indoor_model.edit_selected_cell_space_geometry()
            end
          end
          dialog.add_action_callback('finishEditing') do |_context|
            UI.start_timer(0, false) do
              @indoor_model.request_finish_editing()
            end
          end
          dialog.add_action_callback('clearAllIndoorGmlElements') do |_context|
            puts '[IndoorGML] EditModeDialog#clearAllIndoorGmlElements'
            UI.start_timer(0, false) do
              @indoor_model.clear_all_indoor_gml_elements()
            end
          end
          dialog.set_on_closed do
            puts "[IndoorGML] set_on_closed called, editing=#{@indoor_model.editing?}"
            @indoor_model.finish_editing()
            @dialog = nil
          end if dialog.respond_to?(:set_on_closed)

          return dialog
        end

        def fit_content_height(content_height)
          begin
            return unless @dialog

            requested_height = content_height.to_i + CONTENT_PADDING_HEIGHT + DIALOG_WINDOW_CHROME_HEIGHT
            height = [[requested_height, MIN_DIALOG_HEIGHT].max, MAX_DIALOG_HEIGHT].min
            @dialog.set_size(DIALOG_WIDTH, height)
          rescue StandardError => e
            puts "[IndoorGML] Edit mode dialog resize failed: #{e.class}: #{e.message}"
          end
        end

        def html
          overlay_min_radius = @indoor_model.overlay_min_radius_pixels.round
          overlay_max_radius = @indoor_model.overlay_max_radius_pixels.round
          classification_options = CellSpaceCategory.selection_options.map do |option|
            "<option value=\"#{escape_html(option[:value])}\">#{escape_html(option[:label])}</option>"
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
                .row span:first-child { color: #667484; }
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
                .range-row input[type="range"] { margin-bottom: 0; }
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
                button.danger { background: #a43838; }
                button.danger:hover { background: #842d2d; }
              </style>
            </head>
            <body>
              <div class="header">EDIT MODE - PRIMAL SPACE</div>
              <div class="panel">
                <div class="row"><span>Selected</span><span id="selectedFeature">None</span></div>
                <div class="row"><span>ID</span><span id="selectedId">-</span></div>
                <div class="row"><span>Name</span><span id="selectedName">-</span></div>
                <select id="selectedClassification" disabled>
                  #{classification_options}
                </select>
                <button id="editSelectedCell" type="button" disabled>Edit</button>
              </div>
              <label>
                <span>Overlay radius range</span>
                <output id="overlayRadiusValue">#{overlay_min_radius}-#{overlay_max_radius} px</output>
              </label>
              <div class="range-row">
                <input id="overlayMinRadius" type="range" min="1" max="15" step="1" value="#{overlay_min_radius}">
                <input id="overlayMaxRadius" type="range" min="7" max="25" step="1" value="#{overlay_max_radius}">
              </div>
              <button id="finish" type="button">Finish</button>
              <button id="clearAll" class="danger" type="button">Clear All IndoorGML Elements</button>
              <script>
                var overlayMinRadius = document.getElementById('overlayMinRadius');
                var overlayMaxRadius = document.getElementById('overlayMaxRadius');
                var overlayRadiusValue = document.getElementById('overlayRadiusValue');
                var selectedFeature = document.getElementById('selectedFeature');
                var selectedId = document.getElementById('selectedId');
                var selectedName = document.getElementById('selectedName');
                var selectedClassification = document.getElementById('selectedClassification');
                var editSelectedCell = document.getElementById('editSelectedCell');
                var suppressTypeChange = false;

                function updateSelectedCellSpace(snapshot) {
                  suppressTypeChange = true;
                  if (!snapshot || !snapshot.id) {
                    selectedFeature.textContent = 'None';
                    selectedId.textContent = '-';
                    selectedName.textContent = '-';
                    selectedClassification.disabled = true;
                    selectedClassification.value = 'GeneralSpace|Room';
                    editSelectedCell.disabled = true;
                  } else {
                    selectedFeature.textContent = snapshot.feature || 'CellSpace';
                    selectedId.textContent = snapshot.id || '-';
                    selectedName.textContent = snapshot.name || '-';
                    selectedClassification.disabled = false;
                    selectedClassification.value = snapshot.classification || 'GeneralSpace|Room';
                    editSelectedCell.disabled = false;
                  }
                  suppressTypeChange = false;
                }

                function normalizedOverlayRadiusRange() {
                  var minRadius = Number(overlayMinRadius.value);
                  var maxRadius = Number(overlayMaxRadius.value);
                  overlayRadiusValue.textContent = `${minRadius}-${maxRadius} px`;
                  return [minRadius, maxRadius];
                }

                function previewOverlayRadiusRange() {
                  normalizedOverlayRadiusRange();
                }

                function commitOverlayRadiusRange() {
                  var range = normalizedOverlayRadiusRange();
                  sketchup.setOverlayRadiusRange(range[0], range[1]);
                }

                function fitDialogToContent() {
                  var contentHeight = Math.max(
                    document.body.scrollHeight,
                    document.documentElement.scrollHeight
                  );
                  sketchup.fitContentHeight(contentHeight);
                }

                overlayMinRadius.addEventListener('input', previewOverlayRadiusRange);
                overlayMaxRadius.addEventListener('input', previewOverlayRadiusRange);
                overlayMinRadius.addEventListener('change', commitOverlayRadiusRange);
                overlayMaxRadius.addEventListener('change', commitOverlayRadiusRange);
                selectedClassification.addEventListener('change', function () {
                  if (!suppressTypeChange) {
                    sketchup.setSelectedCellSpaceClassification(selectedClassification.value);
                  }
                });
                editSelectedCell.addEventListener('click', function () {
                  sketchup.editSelectedCellSpace();
                });
                document.getElementById('finish').addEventListener('click', function () {
                  sketchup.finishEditing();
                });
                document.getElementById('clearAll').addEventListener('click', function () {
                  sketchup.clearAllIndoorGmlElements();
                });
                window.addEventListener('load', fitDialogToContent);
                window.addEventListener('resize', fitDialogToContent);
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
                cellType: #{js_string(snapshot[:cell_type])},
                categoryCode: #{js_string(snapshot[:category_code])},
                classification: #{js_string(snapshot[:classification])}
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
