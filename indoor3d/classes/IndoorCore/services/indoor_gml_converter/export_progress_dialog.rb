# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class ExportProgressDialog
          STEPS = [
            [:runtime, 'runtime data refresh'],
            [:temp_file, "\uC784\uC2DC\uD30C\uC77C \uC0DD\uC131"],
            [:val3dity, "val3dity \uC2E4\uD589"],
            [:report, "report \uC0DD\uC131"],
            [:report_view, "report view \uC0DD\uC131"]
          ].freeze

          INITIAL_WIDTH = 380
          INITIAL_HEIGHT = 320

          def initialize
            @dialog = nil
          end

          def show
            dialog.set_html(html)
            dialog.show
          end

          def running(step)
            set_status(step, 'running')
          end

          def complete(step)
            set_status(step, 'complete')
          end

          def pending(step)
            set_status(step, 'pending')
          end

          def fail(step)
            set_status(step, 'failed')
          end

          def close
            @dialog&.close if @dialog&.visible?
            @dialog = nil
          rescue StandardError => e
            puts "[IndoorGML] Export progress close failed: #{e.class}: #{e.message}"
          end

          private

          def dialog
            @dialog ||= UI::HtmlDialog.new(
              dialog_title: 'IndoorGML Export',
              preferences_key: 'ULOL.Indoor3DGmlModeler.ExportProgress',
              scrollable: false,
              resizable: false,
              width: INITIAL_WIDTH,
              height: INITIAL_HEIGHT,
              style: UI::HtmlDialog::STYLE_DIALOG
            )
          end

          def set_status(step, status)
            return unless @dialog&.visible?

            @dialog.execute_script("setStatus(#{step.to_s.inspect}, #{status.inspect});")
          rescue StandardError => e
            puts "[IndoorGML] Export progress update failed: #{e.class}: #{e.message}"
          end

          def html
            rows = STEPS.map do |key, label|
              <<~HTML
                <li id="step-#{key}" class="pending">
                  <span class="icon">&#x23F3;</span>
                  <span class="label">#{escape_html(label)}</span>
                </li>
              HTML
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
                    padding: 18px;
                    font-family: Arial, sans-serif;
                    color: #1f2933;
                    background: #f7f9fb;
                  }
                  .title {
                    font-size: 14px;
                    font-weight: 700;
                    margin-bottom: 14px;
                  }
                  ul {
                    list-style: none;
                    margin: 0;
                    padding: 0;
                  }
                  li {
                    display: flex;
                    align-items: center;
                    gap: 10px;
                    height: 34px;
                    font-size: 13px;
                  }
                  .icon {
                    width: 22px;
                    text-align: center;
                    font-size: 15px;
                  }
                  .pending { color: #6b7684; }
                  .running { color: #0f5da8; font-weight: 700; }
                  .complete { color: #207245; }
                  .failed { color: #a43838; font-weight: 700; }
                </style>
              </head>
              <body>
                <div class="title">Export IndoorGML</div>
                <ul>#{rows}</ul>
                <script>
                  var icons = {
                    pending: String.fromCodePoint(0x23F3),
                    running: String.fromCodePoint(0x1F504),
                    complete: String.fromCodePoint(0x2705),
                    failed: String.fromCodePoint(0x274C)
                  };

                  function setStatus(step, status) {
                    var row = document.getElementById('step-' + step);
                    if (!row) return;
                    row.className = status;
                    row.querySelector('.icon').textContent = icons[status] || icons.pending;
                  }
                </script>
              </body>
              </html>
            HTML
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
end
