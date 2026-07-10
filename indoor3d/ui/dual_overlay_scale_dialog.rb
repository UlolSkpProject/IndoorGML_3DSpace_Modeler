# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DualOverlayScaleDialog
        DIALOG_WIDTH = 360
        CONTENT_HEIGHT = 190
        DIALOG_WINDOW_CHROME_HEIGHT = HtmlDialogMetrics::WINDOW_CHROME_HEIGHT
        DIALOG_HEIGHT = CONTENT_HEIGHT + DIALOG_WINDOW_CHROME_HEIGHT

        def initialize
          @dialog = nil
        end

        def show
          dialog.set_html(html)
          dialog.show
        end

        def close
          request_close
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
            request_close
          end
          dialog.set_on_closed do
            handle_window_closed(dialog)
          end if dialog.respond_to?(:set_on_closed)
          dialog
        end

        def request_close
          current_dialog = @dialog
          current_dialog&.close if dialog_visible_or_unknown?(current_dialog)
          dispose_dialog(current_dialog)
        rescue StandardError => e
          Logger.puts "[IndoorGML] Dual overlay scale dialog close failed: #{e.class}: #{e.message}"
          dispose_dialog(current_dialog)
        end

        def handle_window_closed(closed_dialog)
          dispose_dialog(closed_dialog)
        rescue StandardError => e
          Logger.puts "[IndoorGML] Dual overlay scale dialog window close failed: #{e.class}: #{e.message}"
          @dialog = nil
        end

        def dispose_dialog(closed_dialog)
          @dialog = nil if closed_dialog.nil? || @dialog.equal?(closed_dialog)
        end

        def dialog_visible_or_unknown?(target_dialog)
          return false unless target_dialog
          return target_dialog.visible? if target_dialog.respond_to?(:visible?)

          true
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
                  --focus: #60a5fa;
                  --knob: #fab005;
                  --knob-border: #111827;
                  --state: #2378ff;
                  --state-soft: rgba(35, 120, 255, 0.20);
                  --state-border: #3b82f6;
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
                  color: #93c5fd;
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
                  height: 18px;
                  margin: 2px 0;
                  background: transparent;
                  accent-color: var(--knob);
                  -webkit-appearance: none;
                  appearance: none;
                  --range-progress: 0%;
                }
                input[type="range"]::-webkit-slider-thumb {
                  width: 14px;
                  height: 14px;
                  margin-top: -5px;
                  background: var(--knob);
                  border: 1px solid var(--knob-border);
                  border-radius: 50%;
                  cursor: pointer;
                  -webkit-appearance: none;
                  appearance: none;
                }
                input[type="range"]::-webkit-slider-runnable-track {
                  height: 6px;
                  border: 1px solid #6f6f6f;
                  border-radius: 999px;
                  background: linear-gradient(
                    to right,
                    var(--focus) 0%,
                    var(--focus) var(--range-progress),
                    #515151 var(--range-progress),
                    #515151 100%
                  );
                }
                input[type="range"]::-moz-range-thumb {
                  width: 14px;
                  height: 14px;
                  background: var(--knob);
                  border: 1px solid var(--knob-border);
                  border-radius: 50%;
                  cursor: pointer;
                }
                input[type="range"]::-moz-range-track {
                  height: 6px;
                  border: 1px solid #6f6f6f;
                  border-radius: 999px;
                  background: #515151;
                }
                input[type="range"]::-moz-range-progress {
                  height: 6px;
                  border-radius: 999px;
                  background: var(--focus);
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
                  background: var(--state-soft);
                  border-color: var(--state-border);
                  color: #93c5fd;
                }
                button.primary:hover {
                  border-color: #60a5fa;
                  background: rgba(35, 120, 255, 0.28);
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

                function renderSliderProgress() {
                  const min = Number(slider.min || 0);
                  const max = Number(slider.max || 1000);
                  const value = Number(slider.value || 0);
                  const progress = ((value - min) / (max - min)) * 100;
                  slider.style.setProperty('--range-progress', progress.toFixed(2) + '%');
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
                  renderSliderProgress();
                  render(scale);
                  if (persist) save(scale);
                }

                slider.addEventListener('input', () => {
                  const scale = sliderToScale(slider.value);
                  renderSliderProgress();
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
