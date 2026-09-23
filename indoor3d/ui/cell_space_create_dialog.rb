# frozen_string_literal: true
# encoding: UTF-8

require 'json'
require_relative 'html_dialog_safety'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceCreateDialog
        WIDTH = 520
        FORM_HEIGHT = 430
        RESULT_HEIGHT = 520

        class << self
          def show_conversion_result(result, title: 'CellSpace 변환 완료')
            @result_dialog ||= new
            @result_dialog.show_result(result, title: title)
          end

          def result_payload(result, title:)
            errors = Array(result&.errors)
            converted_count = result&.converted_count.to_i
            metrics = result&.metrics || {}
            status =
              if errors.empty?
                'success'
              elsif converted_count.positive?
                'warning'
              else
                'error'
              end

            {
              title: title,
              status: status,
              converted_count: converted_count,
              error_count: errors.length,
              errors: errors.map do |error|
                {
                  group: error[:group].to_s,
                  reason: error[:reason].to_s
                }
              end,
              metrics: {
                preflight: metrics[:preflight_duration],
                create: metrics[:cell_space_state_duration],
                adjacency: metrics[:adjacency_transition_duration],
                total: metrics[:total_duration]
              }
            }
          end
        end

        def initialize
          @payload = nil
          @on_submit = nil
        end

        def show(payload, &on_submit)
          @payload = payload
          @on_submit = on_submit
          ensure_dialog
          @dialog.set_size(WIDTH, FORM_HEIGHT)
          @dialog.show
          push_form(payload)
          self
        end

        def begin_processing(message = 'CellSpace를 생성하고 있습니다.')
          execute("window.CellSpaceCreateDialog.showProcessing(#{JSON.generate(message.to_s)})")
        end

        def show_result(result, title: 'CellSpace 생성 완료')
          ensure_dialog
          payload = self.class.result_payload(result, title: title)
          @dialog.set_size(WIDTH, RESULT_HEIGHT)
          @dialog.show unless visible?
          execute("window.CellSpaceCreateDialog.showResult(#{JSON.generate(payload)})")
          self
        end

        def show_error(message, title: 'CellSpace 생성 실패')
          ensure_dialog
          payload = {
            title: title,
            status: 'error',
            converted_count: 0,
            error_count: 1,
            errors: [{ group: '', reason: message.to_s }],
            metrics: {}
          }
          @dialog.set_size(WIDTH, RESULT_HEIGHT)
          @dialog.show unless visible?
          execute("window.CellSpaceCreateDialog.showResult(#{JSON.generate(payload)})")
          self
        end

        def close
          @dialog&.close
          @dialog = nil
        rescue StandardError
          @dialog = nil
        end

        private

        def ensure_dialog
          return @dialog if @dialog

          @dialog = ::UI::HtmlDialog.new(
            dialog_title: 'Create CellSpace',
            preferences_key: 'SeoulSpace.IndoorGML.CreateCellSpace',
            scrollable: false,
            resizable: false,
            width: WIDTH,
            height: FORM_HEIGHT,
            style: ::UI::HtmlDialog::STYLE_DIALOG
          )
          @dialog.set_html(html)
          register_callbacks(@dialog)
          @dialog
        end

        def register_callbacks(dialog)
          dialog.add_action_callback('ready') do
            push_form(@payload) if @payload
          end
          dialog.add_action_callback('submit') do |_context, json|
            selection = JSON.parse(json.to_s)
            begin_processing
            callback = @on_submit
            if defined?(::UI) && ::UI.respond_to?(:start_timer)
              ::UI.start_timer(0, false) { callback&.call(selection) }
            else
              callback&.call(selection)
            end
          rescue StandardError => error
            show_error(error.message)
          end
          dialog.add_action_callback('close') { close }
          dialog.set_on_closed do
            @dialog = nil
            @on_submit = nil
          end
        end

        def push_form(payload)
          return unless payload

          execute("window.CellSpaceCreateDialog.showForm(#{JSON.generate(payload)})")
        end

        def visible?
          @dialog && @dialog.visible?
        rescue StandardError
          false
        end

        def execute(script)
          return unless @dialog

          @dialog.execute_script(script)
        rescue StandardError => error
          IndoorCore::Logger.puts(
            "[IndoorGML] Create CellSpace dialog script failed: #{error.class}: #{error.message}"
          ) if defined?(IndoorCore::Logger)
        end

        def html
          <<~HTML
            <!doctype html>
            <html lang="ko">
            <head>
              <meta charset="utf-8">
              <style>
                :root {
                  color-scheme: dark;
                  --background: #1c1c1b;
                  --surface: #242422;
                  --surface-raised: #2b2a28;
                  --surface-hover: #30302d;
                  --border: #373633;
                  --border-strong: #4a4945;
                  --text: #d8d6d0;
                  --text-strong: #e8e6e0;
                  --muted: #85827b;
                  --primary: #8ab4f8;
                  --success: #3ebc71;
                  --warning: #f0c36a;
                  --danger: #f97066;
                  --radius: 7px;
                  --control-height: 34px;
                  --ui-font: "Pretendard", "Malgun Gothic", "Apple SD Gothic Neo", Arial, sans-serif;
                  --mono-font: Consolas, "Malgun Gothic", monospace;
                }

                * { box-sizing: border-box; }
                html, body { margin: 0; min-height: 100%; }
                body {
                  padding: 18px;
                  color: var(--text);
                  background: var(--background);
                  font-family: var(--ui-font);
                  font-size: 13px;
                }
                [hidden] { display: none !important; }

                .header {
                  padding-bottom: 14px;
                  border-bottom: 1px solid var(--border);
                }
                .eyebrow {
                  margin-bottom: 5px;
                  color: var(--primary);
                  font-family: var(--mono-font);
                  font-size: 10px;
                  font-weight: 700;
                  letter-spacing: .08em;
                  text-transform: uppercase;
                }
                h1 {
                  margin: 0;
                  color: var(--text-strong);
                  font-size: 19px;
                  line-height: 1.3;
                }
                .description {
                  margin: 5px 0 0;
                  color: var(--muted);
                  font-size: 11px;
                  line-height: 1.5;
                }

                .form {
                  display: grid;
                  gap: 12px;
                  margin-top: 15px;
                }
                .field label {
                  display: block;
                  margin-bottom: 5px;
                  color: var(--muted);
                  font-size: 10px;
                  font-weight: 700;
                  letter-spacing: .04em;
                }
                select, input {
                  width: 100%;
                  height: var(--control-height);
                  padding: 0 10px;
                  border: 1px solid var(--border-strong);
                  border-radius: var(--radius);
                  color: var(--text);
                  background: var(--surface);
                  font: inherit;
                  outline: none;
                }
                select:focus, input:focus {
                  border-color: var(--primary);
                  box-shadow: 0 0 0 2px rgba(138, 180, 248, .12);
                }
                .hint {
                  margin-top: 5px;
                  color: var(--muted);
                  font-size: 10px;
                }

                .actions {
                  display: flex;
                  justify-content: flex-end;
                  gap: 8px;
                  margin-top: 16px;
                  padding-top: 12px;
                  border-top: 1px solid var(--border);
                }
                button {
                  min-width: 86px;
                  height: var(--control-height);
                  padding: 0 13px;
                  border: 1px solid var(--border-strong);
                  border-radius: var(--radius);
                  color: var(--text);
                  background: var(--surface-raised);
                  font: inherit;
                  font-weight: 700;
                  cursor: pointer;
                }
                button:hover { background: var(--surface-hover); }
                button.primary {
                  border-color: #5378af;
                  color: #eef5ff;
                  background: #315b91;
                }
                button.primary:hover { background: #3a68a2; }

                .processing {
                  display: grid;
                  min-height: 280px;
                  place-items: center;
                  text-align: center;
                }
                .spinner {
                  width: 30px;
                  height: 30px;
                  margin: 0 auto 14px;
                  border: 3px solid var(--border);
                  border-top-color: var(--primary);
                  border-radius: 50%;
                  animation: spin .8s linear infinite;
                }
                @keyframes spin { to { transform: rotate(360deg); } }

                .result { margin-top: 15px; }
                .result-summary {
                  display: grid;
                  grid-template-columns: 1fr 1fr;
                  gap: 10px;
                }
                .summary-card {
                  padding: 12px;
                  border: 1px solid var(--border);
                  border-radius: var(--radius);
                  background: var(--surface);
                }
                .summary-card span {
                  display: block;
                  margin-bottom: 4px;
                  color: var(--muted);
                  font-size: 10px;
                }
                .summary-card strong {
                  font-family: var(--mono-font);
                  font-size: 20px;
                }
                .summary-card.success strong { color: var(--success); }
                .summary-card.error strong { color: var(--danger); }

                .result-state {
                  margin-top: 12px;
                  padding: 10px 12px;
                  border: 1px solid var(--border);
                  border-radius: var(--radius);
                  background: var(--surface-raised);
                  font-weight: 700;
                }
                .result-state.success { color: var(--success); }
                .result-state.warning { color: var(--warning); }
                .result-state.error { color: var(--danger); }

                .metrics {
                  display: grid;
                  grid-template-columns: 1fr 1fr;
                  gap: 6px 12px;
                  margin-top: 12px;
                  padding: 10px 12px;
                  border: 1px solid var(--border);
                  border-radius: var(--radius);
                  background: var(--surface);
                  font-family: var(--mono-font);
                  font-size: 10px;
                }
                .metric {
                  display: flex;
                  justify-content: space-between;
                  gap: 8px;
                }
                .metric span:first-child { color: var(--muted); }

                .errors {
                  max-height: 150px;
                  margin-top: 12px;
                  overflow: auto;
                  border: 1px solid var(--border);
                  border-radius: var(--radius);
                  background: var(--surface);
                }
                .error-row {
                  padding: 9px 11px;
                  border-bottom: 1px solid var(--border);
                }
                .error-row:last-child { border-bottom: 0; }
                .error-group {
                  color: var(--text-strong);
                  font-size: 11px;
                  font-weight: 700;
                }
                .error-reason {
                  margin-top: 3px;
                  color: var(--danger);
                  font-size: 10px;
                  line-height: 1.4;
                  white-space: pre-wrap;
                }
              </style>
            </head>
            <body>
              <div class="header">
                <div class="eyebrow">SeoulSpace IndoorGML Modeler</div>
                <h1 id="title">CellSpace 생성</h1>
                <p id="description" class="description">선택한 Solid Group을 CellSpace로 변환합니다.</p>
              </div>

              <section id="formView">
                <div class="form">
                  <div class="field">
                    <label for="buildingType">건축물 구분</label>
                    <select id="buildingType"></select>
                  </div>
                  <div class="field">
                    <label for="cellSpaceType">CellSpace 유형 · 유효 Tag가 없을 때</label>
                    <select id="cellSpaceType"></select>
                  </div>
                  <div class="field">
                    <label for="storey">층</label>
                    <input id="storey" type="text" autocomplete="off" placeholder="F01 또는 F01~F03">
                    <div class="hint">예: F01, B01, F01~F03</div>
                  </div>
                </div>
                <div class="actions">
                  <button id="cancel" type="button">취소</button>
                  <button id="create" class="primary" type="button">생성</button>
                </div>
              </section>

              <section id="processingView" class="processing" hidden>
                <div>
                  <div class="spinner"></div>
                  <strong>처리 중</strong>
                  <div id="processingMessage" class="description"></div>
                </div>
              </section>

              <section id="resultView" class="result" hidden>
                <div class="result-summary">
                  <div class="summary-card success"><span>성공</span><strong id="successCount">0</strong></div>
                  <div class="summary-card error"><span>실패</span><strong id="errorCount">0</strong></div>
                </div>
                <div id="resultState" class="result-state"></div>
                <div id="metrics" class="metrics" hidden></div>
                <div id="errors" class="errors" hidden></div>
                <div class="actions">
                  <button id="close" class="primary" type="button">닫기</button>
                </div>
              </section>

              <script>
                (function () {
                  var formView = document.getElementById('formView');
                  var processingView = document.getElementById('processingView');
                  var resultView = document.getElementById('resultView');
                  var buildingType = document.getElementById('buildingType');
                  var cellSpaceType = document.getElementById('cellSpaceType');
                  var storey = document.getElementById('storey');
                  var title = document.getElementById('title');
                  var description = document.getElementById('description');

                  function fillSelect(select, options, selected) {
                    select.innerHTML = '';
                    (options || []).forEach(function (option) {
                      var node = document.createElement('option');
                      node.value = option.value;
                      node.textContent = option.label;
                      select.appendChild(node);
                    });
                    if (selected !== undefined && selected !== null) select.value = selected;
                  }

                  function showOnly(view) {
                    formView.hidden = view !== formView;
                    processingView.hidden = view !== processingView;
                    resultView.hidden = view !== resultView;
                  }

                  function metricRow(label, value) {
                    if (value === null || value === undefined) return '';
                    var seconds = Number(value);
                    if (!Number.isFinite(seconds)) return '';
                    return '<div class="metric"><span>' + label + '</span><span>' + seconds.toFixed(3) + ' s</span></div>';
                  }

                  window.CellSpaceCreateDialog = {
                    showForm: function (payload) {
                      payload = payload || {};
                      title.textContent = payload.title || 'CellSpace 생성';
                      description.textContent = payload.description || '선택한 Solid Group을 CellSpace로 변환합니다.';
                      fillSelect(buildingType, payload.building_types || [], payload.selected_building);
                      fillSelect(cellSpaceType, payload.cell_space_options || [], payload.selected_cell_space);
                      storey.value = payload.storey || 'F01';
                      showOnly(formView);
                    },

                    showProcessing: function (message) {
                      title.textContent = 'CellSpace 생성 중';
                      description.textContent = '선택한 형상을 IndoorGML CellSpace로 변환하고 있습니다.';
                      document.getElementById('processingMessage').textContent = message || '';
                      showOnly(processingView);
                    },

                    showResult: function (payload) {
                      payload = payload || {};
                      title.textContent = payload.title || 'CellSpace 완료';
                      description.textContent = 'CellSpace 처리 결과입니다.';
                      document.getElementById('successCount').textContent = payload.converted_count || 0;
                      document.getElementById('errorCount').textContent = payload.error_count || 0;

                      var state = document.getElementById('resultState');
                      state.className = 'result-state ' + (payload.status || 'success');
                      if (payload.status === 'success') state.textContent = '모든 CellSpace 처리가 완료되었습니다.';
                      else if (payload.status === 'warning') state.textContent = '일부 CellSpace 처리에 실패했습니다.';
                      else state.textContent = 'CellSpace 처리에 실패했습니다.';

                      var metrics = payload.metrics || {};
                      var metricsNode = document.getElementById('metrics');
                      metricsNode.innerHTML =
                        metricRow('시작 전 검사', metrics.preflight) +
                        metricRow('CellSpace / State', metrics.create) +
                        metricRow('Adjacency / Transition', metrics.adjacency) +
                        metricRow('전체', metrics.total);
                      metricsNode.hidden = metricsNode.innerHTML === '';

                      var errorsNode = document.getElementById('errors');
                      errorsNode.innerHTML = '';
                      (payload.errors || []).forEach(function (error) {
                        var row = document.createElement('div');
                        row.className = 'error-row';
                        var group = document.createElement('div');
                        group.className = 'error-group';
                        group.textContent = error.group || '오류';
                        var reason = document.createElement('div');
                        reason.className = 'error-reason';
                        reason.textContent = error.reason || '알 수 없는 오류';
                        row.appendChild(group);
                        row.appendChild(reason);
                        errorsNode.appendChild(row);
                      });
                      errorsNode.hidden = errorsNode.children.length === 0;
                      showOnly(resultView);
                    }
                  };

                  document.getElementById('create').addEventListener('click', function () {
                    if (!window.sketchup || !window.sketchup.submit) return;
                    window.sketchup.submit(JSON.stringify({
                      building_type: buildingType.value,
                      cell_space_label: cellSpaceType.value,
                      storey: storey.value
                    }));
                  });
                  document.getElementById('cancel').addEventListener('click', function () {
                    if (window.sketchup && window.sketchup.close) window.sketchup.close();
                  });
                  document.getElementById('close').addEventListener('click', function () {
                    if (window.sketchup && window.sketchup.close) window.sketchup.close();
                  });

                  if (window.sketchup && window.sketchup.ready) window.sketchup.ready();
                }());
              </script>
            </body>
            </html>
          HTML
        end
      end
    end
  end
end
