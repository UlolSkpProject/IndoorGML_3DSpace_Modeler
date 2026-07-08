# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DualOverlayScaleDialog
        DIALOG_WIDTH = 360
        CONTENT_HEIGHT = 190
        DIALOG_WINDOW_CHROME_HEIGHT = 44
        DIALOG_HEIGHT = CONTENT_HEIGHT + DIALOG_WINDOW_CHROME_HEIGHT

        def initialize
          @dialog = nil
        end

        def show
          dialog.set_html(html)
          dialog.show
        end

        def apply_state_radius_scale(value)
          scale = value.to_f.round(2)
          DualOverlayPreferences.state_radius_scale = scale
          invalidate_active_view
          DualOverlayPreferences.state_radius_scale
        rescue StandardError => e
          Logger.puts "[IndoorGML] Dual overlay scale update failed: #{e.class}: #{e.message}"
          DualOverlayPreferences::STATE_RADIUS_SCALE_DEFAULT
        end

        def reset_state_radius_scale
          DualOverlayPreferences.state_radius_scale = DualOverlayPreferences::STATE_RADIUS_SCALE_DEFAULT
          invalidate_active_view
          DualOverlayPreferences.state_radius_scale
        rescue StandardError => e
          Logger.puts "[IndoorGML] Dual overlay scale reset failed: #{e.class}: #{e.message}"
          DualOverlayPreferences::STATE_RADIUS_SCALE_DEFAULT
        end

        private

        def dialog
          @dialog ||= build_dialog
        end

        def build_dialog
          dialog = UI::HtmlDialog.new(
            dialog_title: 'State/Link Overlay Scale',
            preferences_key: 'ULOL.Indoor3DGmlModeler.DualOverlayScale',
            scrollable: false,
            resizable: false,
            width: DIALOG_WIDTH,
            height: DIALOG_HEIGHT,
            style: UI::HtmlDialog::STYLE_UTILITY
          )
          dialog.add_action_callback('setStateRadiusScale') do |_context, value|
            apply_state_radius_scale(value)
          end
          dialog.add_action_callback('resetStateRadiusScale') do |_context|
            reset_state_radius_scale
          end
          dialog.add_action_callback('closeDialog') do |_context|
            dialog.close
          end
          dialog
        end

        def invalidate_active_view
          Sketchup.active_model&.active_view&.invalidate
        rescue StandardError => e
          Logger.puts "[IndoorGML] Dual overlay scale view invalidation failed: #{e.class}: #{e.message}"
        end

        def html
          scale = DualOverlayPreferences.state_radius_scale
          min_scale = DualOverlayPreferences::STATE_RADIUS_SCALE_MIN
          max_scale = DualOverlayPreferences::STATE_RADIUS_SCALE_MAX
          default_scale = DualOverlayPreferences::STATE_RADIUS_SCALE_DEFAULT
          <<~HTML
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <style>
                :root {
                  --bg: #1c1c1b;
                  --panel: #242422;
                  --border: #373633;
                  --field-border: #4a4945;
                  --track: #33322f;
                  --text: #d8d6d0;
                  --text-strong: #e8e6e0;
                  --text-muted: #85827b;
                  --focus: #8ab4f8;
                  --accent: #3ebc71;
                  --accent-bg: #12261a;
                  --accent-border: #327a4f;
                  --radius: 8px;
                }
                * {
                  box-sizing: border-box;
                }
                html {
                  overflow: hidden;
                  user-select: none;
                  -webkit-user-select: none;
                }
                body {
                  margin: 0;
                  padding: 16px;
                  overflow: hidden;
                  font-family: Arial, sans-serif;
                  color: var(--text);
                  background: var(--bg);
                  font-size: 12px;
                }
                .header {
                  display: flex;
                  align-items: baseline;
                  justify-content: space-between;
                  gap: 12px;
                  padding-bottom: 12px;
                  border-bottom: 1px solid var(--border);
                  margin-bottom: 12px;
                }
                .label {
                  color: var(--text-muted);
                  font-size: 11px;
                  font-weight: 700;
                  letter-spacing: 0.08em;
                  text-transform: uppercase;
                }
                .value {
                  color: var(--text-strong);
                  font-size: 18px;
                  font-weight: 700;
                  font-variant-numeric: tabular-nums;
                }
                .scale-panel {
                  padding: 12px;
                  border: 1px solid var(--border);
                  border-radius: var(--radius);
                  background: var(--panel);
                }
                input[type="range"] {
                  width: 100%;
                  accent-color: var(--focus);
                }
                .range-labels {
                  display: flex;
                  justify-content: space-between;
                  margin-top: 4px;
                  font-size: 11px;
                  color: var(--text-muted);
                }
                .actions {
                  display: flex;
                  justify-content: flex-end;
                  gap: 8px;
                  margin-top: 18px;
                }
                button {
                  min-width: 72px;
                  height: 30px;
                  border: 1px solid var(--field-border);
                  border-radius: 7px;
                  background: transparent;
                  color: var(--text);
                  cursor: pointer;
                  font-family: Arial, sans-serif;
                  font-size: 12px;
                  font-weight: 700;
                }
                button:hover {
                  border-color: #6a6760;
                }
                button.primary {
                  background: var(--accent-bg);
                  border-color: var(--accent-border);
                  color: var(--accent);
                }
                button.primary:hover {
                  border-color: #3a9060;
                  background: #152e1e;
                }
              </style>
            </head>
            <body>
              <div class="header">
                <div class="label">State radius scale</div>
                <div id="scaleValue" class="value"></div>
              </div>
              <div class="scale-panel">
                <input id="scaleSlider" type="range" min="0" max="1000" step="1">
                <div class="range-labels">
                  <span>#{format('%.1f', min_scale)}x</span>
                  <span>#{format('%.1f', max_scale)}x</span>
                </div>
              </div>
              <div class="actions">
                <button id="resetButton" type="button">Reset</button>
                <button id="closeButton" class="primary" type="button">Close</button>
              </div>
              <script>
                const MIN_SCALE = #{min_scale};
                const MAX_SCALE = #{max_scale};
                const DEFAULT_SCALE = #{default_scale};
                const INITIAL_SCALE = #{scale};
                const slider = document.getElementById('scaleSlider');
                const valueLabel = document.getElementById('scaleValue');
                let saveTimer = null;

                function sliderToScale(position) {
                  const t = Number(position) / 1000.0;
                  return MIN_SCALE * Math.pow(MAX_SCALE / MIN_SCALE, t);
                }

                function scaleToSlider(scale) {
                  const clamped = Math.min(MAX_SCALE, Math.max(MIN_SCALE, Number(scale)));
                  const t = Math.log(clamped / MIN_SCALE) / Math.log(MAX_SCALE / MIN_SCALE);
                  return Math.round(t * 1000);
                }

                function roundedScale(scale) {
                  return Math.round(scale * 100) / 100;
                }

                function render(scale) {
                  valueLabel.textContent = roundedScale(scale).toFixed(2) + 'x';
                }

                function save(scale) {
                  window.sketchup.setStateRadiusScale(String(roundedScale(scale)));
                }

                function debounceSave(scale) {
                  if (saveTimer) window.clearTimeout(saveTimer);
                  saveTimer = window.setTimeout(() => save(scale), 75);
                }

                function setScale(scale, persist) {
                  slider.value = String(scaleToSlider(scale));
                  render(scale);
                  if (persist) save(scale);
                }

                slider.addEventListener('input', () => {
                  const scale = sliderToScale(slider.value);
                  render(scale);
                  debounceSave(scale);
                });

                slider.addEventListener('change', () => {
                  if (saveTimer) window.clearTimeout(saveTimer);
                  save(sliderToScale(slider.value));
                });

                document.getElementById('resetButton').addEventListener('click', () => {
                  if (saveTimer) window.clearTimeout(saveTimer);
                  setScale(DEFAULT_SCALE, false);
                  window.sketchup.resetStateRadiusScale();
                });

                document.getElementById('closeButton').addEventListener('click', () => {
                  window.sketchup.closeDialog();
                });

                setScale(INITIAL_SCALE, false);
              </script>
            </body>
            </html>
          HTML
        end
      end
    end
  end
end
