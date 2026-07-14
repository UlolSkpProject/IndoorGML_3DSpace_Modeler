# frozen_string_literal: true

require_relative 'val3dity_report_schema'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class Val3dityReportRenderer
          OVERLAP_RECHECK_REPORT_KEY = Val3dityReportSchema::OVERLAP_RECHECK_REPORT_KEY
          STRICT_VALIDITY_KEY = Val3dityReportSchema::STRICT_VALIDITY_KEY
          EXTENSION_VALIDITY_KEY = Val3dityReportSchema::EXTENSION_VALIDITY_KEY
          VALIDATION_STATUS_KEY = Val3dityReportSchema::VALIDATION_STATUS_KEY

          def render(raw_report)
            fallback_report_html(raw_report)
          end

          private

          def fallback_report_html(raw_report)
            <<~HTML
              <!doctype html>
              <html>
              <head>
                <meta charset="utf-8">
                <title>val3dity report</title>
                <style>
                  :root {
                    color-scheme: dark;
                    font-family: Arial, sans-serif;
                    color: #d8d6d0;
                    background: #1c1c1b;
                    scrollbar-gutter: stable;
                  }
                  * { box-sizing: border-box; }
                  html { user-select: none; -webkit-user-select: none; }
                  body { margin: 0; padding: 10px 0; background: #1c1c1b; }
                  main { max-width: 450px; margin: 0 auto; padding: 0 10px; }
                  .hero { padding: 10px 0 16px; border-bottom: 1px solid #373633; }
                  .hero-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
                  .hero-title { display: flex; align-items: center; gap: 7px; min-height: 31px; }
                  .top-meta { margin-bottom: 12px; color: #85827b; font-size: 11px; line-height: 1.55; }
                  .eyebrow { margin-bottom: 6px; color: #85827b; font-size: 11px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
                  h1 { margin: 0; color: #e8e6e0; font-size: 22px; line-height: 1.15; }
                  .result-message { margin: 8px 0 0; color: #b9b6ae; font-size: 12px; line-height: 1.5; }
                  .result-badge { display: inline-flex; align-items: center; padding: 5px 13px; border-radius: 999px; font-size: 12px; font-weight: 700; white-space: nowrap; }
                  .result-badge.valid { color: #3ebc71; background: #12261a; border: 1px solid #327a4f; }
                  .result-badge.invalid { color: #f97066; background: #351918; border: 1px solid #7a2e2a; }
                  .fix-action { display: inline-flex; align-items: center; padding: 5px 13px; border-radius: 999px; font-size: 12px; font-weight: 700; white-space: nowrap; color: #8ab4f8; background: #17243b; border: 1px solid #315d9b; cursor: pointer; }
                  .fix-action:hover { background: #1d2d4a; border-color: #4278c7; }
                  .result-metrics { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin-top: 16px; }
                  .result-metric { min-height: 64px; padding: 11px 14px; background: #242422; border-radius: 8px; }
                  .metric-value { display: block; color: #3ebc71; font-size: 20px; font-weight: 700; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
                  .metric-value.info { color: #8ab4f8; }
                  .metric-label { display: block; margin-top: 5px; color: #85827b; font-size: 11px; }
                  .section { padding-top: 18px; margin-top: 0; }
                  .section + .section { border-top: 1px solid #373633; margin-top: 18px; }
                  .section-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 10px; }
                  h2 { margin: 0; color: #a8a49d; font-size: 12px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; }
                  .section-count { color: #85827b; font-size: 12px; white-space: nowrap; }
                  .params-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
                  .param { min-width: 0; padding: 10px 12px; background: #242422; border-radius: 8px; }
                  .param-label { color: #85827b; font-family: Consolas, Monaco, monospace; font-size: 10px; letter-spacing: .03em; }
                  .param-value { margin-top: 3px; color: #e8e6e0; font-family: Consolas, Monaco, monospace; font-size: 13px; overflow-wrap: anywhere; }
                  .filter-row { display: flex; gap: 7px; margin-bottom: 10px; overflow-x: auto; padding-bottom: 2px; }
                  .filter-btn { flex: 0 0 auto; padding: 8px 13px; border: 1px solid #4a4945; border-radius: 8px; background: transparent; color: #b9b6ae; cursor: pointer; font-size: 12px; font-weight: 700; }
                  .filter-btn.active { border-color: #327a4f; background: #12261a; color: #d8d6d0; }
                  .report-actions { display: flex; justify-content: flex-end; }
                  .report-action { min-width: 92px; padding: 8px 12px; border: 1px solid #5a5953; border-radius: 7px; background: #343432; color: #e8e6e0; cursor: pointer; font-size: 12px; font-weight: 700; white-space: nowrap; }
                  .report-action:hover { background: #3d3d3a; border-color: #6a6962; }
                  .recheck-list { display: grid; gap: 8px; }
                  .recheck-row { background: #242422; border: 1px solid #2f2e2b; border-radius: 8px; }
                  .recheck-row.focused { border-color: #ef4444; box-shadow: inset 0 0 0 1px rgba(239, 68, 68, .55); }
                  .recheck-row.c100.focused { border-color: #f87171; box-shadow: inset 0 0 0 1px rgba(248, 113, 113, .6); }
                  .recheck-row.c200.focused { border-color: #74d66f; box-shadow: inset 0 0 0 1px rgba(116, 214, 111, .6); }
                  .recheck-row.c300.focused { border-color: #f6b45b; box-shadow: inset 0 0 0 1px rgba(246, 180, 91, .6); }
                  .recheck-row.c400.focused { border-color: #22d3ee; box-shadow: inset 0 0 0 1px rgba(34, 211, 238, .6); }
                  .recheck-row.c500.focused { border-color: #bbf7b8; box-shadow: inset 0 0 0 1px rgba(187, 247, 184, .6); }
                  .recheck-row.c600.focused { border-color: #d6a36d; box-shadow: inset 0 0 0 1px rgba(214, 163, 109, .6); }
                  .recheck-row.c700.focused { border-color: #f472b6; box-shadow: inset 0 0 0 1px rgba(244, 114, 182, .6); }
                  .recheck-row.c900.focused { border-color: #fef08a; box-shadow: inset 0 0 0 1px rgba(254, 240, 138, .6); }
                  .recheck-row summary { display: grid; grid-template-columns: auto 1fr auto; align-items: center; gap: 8px; padding: 8px 9px; cursor: pointer; list-style: none; }
                  .recheck-row summary::-webkit-details-marker { display: none; }
                  .recheck-row[open] summary { border-bottom: 1px solid #33322f; }
                  .recheck-summary-main { display: flex; align-items: center; gap: 7px; min-width: 0; }
                  .recheck-summary-main .cell-name { font-size: 10px; }
                  .occurrence-badge { flex: 0 0 auto; padding: 2px 6px; border-radius: 999px; background: #353431; color: #b9b6ae; font-size: 9px; font-weight: 700; white-space: nowrap; }
                  .summary-distance { color: #e8e6e0; font-family: Consolas, Monaco, monospace; font-size: 11px; text-align: right; white-space: nowrap; }
                  .summary-distance sup { font-size: 8px; line-height: 0; }
                  .recheck-detail { display: grid; gap: 6px; padding: 8px 9px 9px; }
                  .error-member { display: grid; gap: 4px; padding: 7px 0; border-top: 1px solid #33322f; }
                  .error-member:first-child { padding-top: 0; border-top: 0; }
                  .error-member:last-child { padding-bottom: 0; }
                  .member-heading { color: #d8d6d0; font-size: 10px; font-weight: 700; }
                  .member-field { display: grid; grid-template-columns: 92px minmax(0, 1fr); gap: 7px; font-size: 10px; line-height: 1.4; }
                  .member-label { color: #85827b; }
                  .member-value { color: #b9b6ae; overflow-wrap: anywhere; user-select: text; -webkit-user-select: text; }
                  .code-badge { display: inline-flex; align-items: center; padding: 3px 7px; border-radius: 5px; background: #1d355d; color: #8ab4f8; font-family: Consolas, Monaco, monospace; font-size: 11px; font-weight: 700; }
                  .code-badge.c704 { background: #443815; color: #e5c567; }
                  .code-badge.c100 { background: #451a1a; color: #fca5a5; }
                  .code-badge.c200 { background: #16351a; color: #86efac; }
                  .code-badge.c300 { background: #44270d; color: #fdba74; }
                  .code-badge.c400 { background: #083344; color: #67e8f9; }
                  .code-badge.c500 { background: #1b3a1b; color: #bbf7d0; }
                  .code-badge.c600 { background: #3b2716; color: #d6a36d; }
                  .code-badge.c700 { background: #4a1735; color: #f9a8d4; }
                  .code-badge.c900 { background: #3f3b12; color: #fef08a; }
                  .status-badge { color: #3ebc71; font-size: 11px; font-weight: 700; text-transform: uppercase; }
                  .status-badge.kept, .status-badge.inconclusive { color: #f9b84e; }
                  .cell-pair { display: grid; gap: 3px; min-width: 0; color: #d8d6d0; font-family: Consolas, Monaco, monospace; font-size: 11px; line-height: 1.35; }
                  .cell-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: text; user-select: text; -webkit-user-select: text; }
                  .reason { color: #a8a49d; font-size: 11px; line-height: 1.45; overflow-wrap: anywhere; }
                  .empty { color: #85827b; margin: 0; font-size: 12px; }
                  details.section > summary.section-head { cursor: pointer; list-style: none; }
                  details.section > summary.section-head::-webkit-details-marker { display: none; }
                  .toggle-triangle { display: inline-block; width: 0; height: 0; margin-right: 8px; border-top: 5px solid transparent; border-bottom: 5px solid transparent; border-left: 7px solid #85827b; transition: transform .12s ease-out; }
                  details[open] > summary .toggle-triangle { transform: rotate(90deg); }
                  code { background: #242422; border-radius: 4px; padding: 1px 4px; color: #d8d6d0; }
                  @media (min-width: 700px) {
                    body { padding: 20px 0; }
                    main { max-width: 540px; padding: 0 10px; }
                  }
                </style>
              </head>
              <body>
                <main>
                  #{report_top_meta_section(raw_report)}
                  #{report_result_hero_section(raw_report)}
                  #{report_summary_section(raw_report)}
                  #{report_issue_sections(raw_report)}
                  #{report_filter_script}
                </main>
              </body>
              </html>
            HTML
          end

          def report_result_hero_section(raw_report)
            final_errors = final_error_count(raw_report)
            validity = final_errors.zero?
            suppressed = overlap_recheck_suppressed_count(raw_report)
            kept = overlap_recheck_kept_count(raw_report)
            inconclusive = overlap_recheck_inconclusive_count(raw_report)
            primitive_value = "#{valid_count(raw_report['primitives_overview'])} / #{total_count(raw_report['primitives_overview'])}"
            badge_class = validity ? 'result-badge valid' : 'result-badge invalid'
            fix_button = validity ? '' : '<button class="fix-action" type="button" onclick="if (window.sketchup && sketchup.fixValidationErrors) { sketchup.fixValidationErrors(); }">FIX</button>'
            message = result_hero_message(raw_report, final_errors, suppressed, kept, inconclusive)
            <<~HTML
              <section class="hero">
                <div class="hero-top">
                  <div>
                    <div class="eyebrow">IndoorGML · val3dity #{html_escape(raw_report['val3dity_version'] || 'unknown')}</div>
                    <div class="hero-title">
                      <span class="#{badge_class}">#{validity ? 'VALID' : 'INVALID'}</span>
                      #{fix_button}
                    </div>
                    <p class="result-message">#{html_escape(message)}</p>
                  </div>
                  <div class="report-actions">
                    <button class="report-action" type="button" onclick="if (window.sketchup && sketchup.createGml) { sketchup.createGml(); }">Export GML</button>
                  </div>
                </div>
                <div class="result-metrics">
                  <div class="result-metric">
                    <span class="metric-value">#{final_errors}</span>
                    <span class="metric-label">최종 오류</span>
                  </div>
                  <div class="result-metric">
                    <span class="metric-value">#{suppressed}</span>
                    <span class="metric-label">억제됨</span>
                  </div>
                  <div class="result-metric">
                    <span class="metric-value">#{kept}</span>
                    <span class="metric-label">유지됨</span>
                  </div>
                  <div class="result-metric">
                    <span class="metric-value info">#{html_escape(primitive_value)}</span>
                    <span class="metric-label">유효 Primitive</span>
                  </div>
                </div>
              </section>
            HTML
          end

          def report_top_meta_section(raw_report)
            <<~HTML
              <div class="top-meta">
                <div>#{html_escape(report_checked_at(raw_report['time']))}</div>
                <div>strict: #{html_escape(raw_report[STRICT_VALIDITY_KEY] == true ? 'valid' : 'invalid')} · extension policy: #{html_escape(raw_report[EXTENSION_VALIDITY_KEY] == true ? 'valid' : 'invalid')} · features #{valid_count(raw_report['features_overview'])}/#{total_count(raw_report['features_overview'])}</div>
              </div>
            HTML
          end

          def report_issue_sections(raw_report)
            [
              report_error_items_section(
                grouped_error_item_rows(raw_report),
                title: 'ERROR',
                raw_report: raw_report
              ),
              report_overlap_recheck_section(
                overlap_recheck_suppressed_rows(raw_report),
                title: 'Suppressed',
                collapsed: true
              )
            ].join
          end

          def report_error_items_section(rows, title:, raw_report: nil)
            return '' if rows.empty?

            <<~HTML
              <section class="section">
                <div class="section-head">
                  <h2>#{html_escape(title)}</h2>
                  <span class="section-count">#{rows.length}건</span>
                </div>
                #{report_filter_row(rows)}
                <div class="recheck-list">
                  #{error_item_rows_html(rows, raw_report)}
                </div>
              </section>
            HTML
          end

          def report_summary_section(raw_report)
            <<~HTML
              <section class="section">
                <div class="section-head">
                  <h2>파라미터</h2>
                </div>
                <div class="params-grid">
                  #{parameter_html('snap_tol', raw_report.dig('parameters', 'snap_tol') || '-')}
                  #{parameter_html('overlap_tol', raw_report.dig('parameters', 'overlap_tol') || '-')}
                  #{parameter_html('planarity_d2p', raw_report.dig('parameters', 'planarity_d2p_tol') || '-')}
                  #{parameter_html('planarity_n', raw_report.dig('parameters', 'planarity_n_tol') || '-')}
                </div>
              </section>
            HTML
          end

          def parameter_html(label, value)
            <<~HTML
              <div class="param">
                <div class="param-label">#{html_escape(label)}</div>
                <div class="param-value">#{html_escape(value)}</div>
              </div>
            HTML
          end

          def result_hero_message(raw_report, final_errors, suppressed, kept, inconclusive)
            total_rechecks = suppressed + kept + inconclusive
            return 'strict val3dity 오류가 없습니다.' if raw_report[VALIDATION_STATUS_KEY] == 'exact_valid'
            if %w[extension_policy_valid tolerance_valid].include?(raw_report[VALIDATION_STATUS_KEY])
              return "strict val3dity 오류는 있었지만 최종 오류가 없습니다. Overlap 재검사 후보 #{suppressed}건이 extension policy로 억제되었습니다."
            end
            return "실제 수정이 필요한 오류가 #{final_errors}건 남아 있습니다." if total_rechecks.zero?

            "실제 수정이 필요한 오류가 #{final_errors}건 남아 있습니다. Overlap 재검사 후보 #{total_rechecks}건 중 #{suppressed}건은 억제, #{kept}건은 유지, #{inconclusive}건은 불명확입니다."
          end

          def final_error_count(raw_report)
            grouped_error_item_rows(raw_report).length
          end

          def overlap_recheck_suppressed_count(raw_report)
            overlap_recheck_rows(raw_report).count { |row| row['tolerated'] == true }
          end

          def overlap_recheck_kept_count(raw_report)
            overlap_recheck_rows(raw_report).count { |row| row['status'] == 'kept' || (row['status'].nil? && row['tolerated'] != true) }
          end

          def overlap_recheck_inconclusive_count(raw_report)
            overlap_recheck_rows(raw_report).count { |row| row['status'] == 'inconclusive' }
          end

          def overlap_recheck_rows(raw_report)
            Array(raw_report[OVERLAP_RECHECK_REPORT_KEY])
          end

          def overlap_recheck_suppressed_rows(raw_report)
            overlap_recheck_rows(raw_report).select { |row| row['tolerated'] == true }
          end

          def report_checked_at(value)
            text = value.to_s.strip
            return '-' if text.empty?

            text.gsub('대한민국 표준시', 'KST')
          end

          def report_overlap_recheck_section(rows, title:, collapsed: false)
            return '' if rows.empty?

            body = <<~HTML
              #{report_filter_row(rows)}
              <div class="recheck-list">
                #{rows.map { |row| overlap_recheck_row_html(row) }.join}
              </div>
            HTML
            return <<~HTML if collapsed
              <details class="section">
                <summary class="section-head">
                  <h2><span class="toggle-triangle" aria-hidden="true"></span>#{html_escape(title)}</h2>
                  <span class="section-count">#{rows.length}건</span>
                </summary>
                #{body}
              </details>
            HTML

            <<~HTML
              <section class="section">
                <div class="section-head">
                  <h2>#{html_escape(title)}</h2>
                  <span class="section-count">#{rows.length}건</span>
                </div>
                #{body}
              </section>
            HTML
          end

          def overlap_recheck_row_html(row)
            cells = Array(row['cells'])
            code = row['code'].to_s
            distance = format_report_distance_mm(row['distance_mm'])
            <<~HTML
              <details class="recheck-row #{error_code_color_class(code)}" data-code="#{html_escape(code)}">
                <summary>
                  <span class="code-badge #{error_code_color_class(code)}">#{html_escape(code)}</span>
                  <span class="recheck-summary-main">
                    <span class="cell-name" title="#{html_escape(cells.join(' / '))}">#{html_escape(compact_cell_pair(cells))}</span>
                  </span>
                  <span class="summary-distance">#{distance}</span>
                </summary>
                <div class="recheck-detail">
                  <div class="cell-pair">
                    <span class="cell-name" title="#{html_escape(cells[0] || '-')}">#{html_escape(cells[0] || '-')}</span>
                    <span class="cell-name" title="#{html_escape(cells[1] || '-')}">#{html_escape(cells[1] || '-')}</span>
                  </div>
                  <div class="reason">#{html_escape(compact_overlap_reason(row['reason']))}</div>
                </div>
              </details>
            HTML
          end

          def report_filter_row(rows)
            counts = Hash.new(0)
            rows.each { |row| counts[report_row_code(row)] += 1 }
            buttons = counts.keys.sort_by { |code| [error_code_number(code), code.to_s] }.map do |code|
              <<~HTML
                <button class="filter-btn" type="button" data-filter="#{html_escape(code)}">#{html_escape(code)} (#{counts[code]})</button>
              HTML
            end.join

            <<~HTML
              <div class="filter-row" aria-label="Error code filters">
                <button class="filter-btn active" type="button" data-filter="all">전체 #{rows.length}</button>
                #{buttons}
              </div>
            HTML
          end

          def report_row_code(row)
            (row.respond_to?(:[]) && (row['code'] || row[:code])).to_s
          end

          def error_code_color_class(code)
            number = error_code_number(code)
            return 'c100' if (100..199).include?(number)
            return 'c200' if (200..299).include?(number)
            return 'c300' if (300..399).include?(number)
            return 'c400' if (400..499).include?(number)
            return 'c500' if (500..599).include?(number)
            return 'c600' if (600..699).include?(number)
            return 'c700' if (700..799).include?(number)
            return 'c900' if (900..999).include?(number)

            ''
          end

          def report_filter_script
            <<~HTML
              <script>
                document.querySelectorAll('.validation-error-row').forEach(function(row) {
                  row.addEventListener('click', function(event) {
                    event.stopPropagation();
                    var rowId = row.getAttribute('data-row-id') || '';
                    var cells = (row.getAttribute('data-cells') || '').split(',').filter(Boolean);
                    var states = (row.getAttribute('data-states') || '').split(',').filter(Boolean);
                    var transitions = (row.getAttribute('data-transitions') || '').split(',').filter(Boolean);
                    var code = row.getAttribute('data-code') || '';
                    document.querySelectorAll('.validation-error-row.focused').forEach(function(item) {
                      item.classList.remove('focused');
                    });
                    row.classList.add('focused');
                    if ((cells.length > 0 || states.length > 0 || transitions.length > 0) && typeof sketchup !== 'undefined' && sketchup.focusValidationCells) {
                      sketchup.focusValidationCells(cells, code, states, transitions, rowId);
                    }
                  });
                });
                document.addEventListener('click', function(event) {
                  if (event.target.closest('.validation-error-row') || event.target.closest('.filter-btn')) return;
                  window.clearValidationFocusSelection();
                  if (typeof sketchup !== 'undefined' && sketchup.focusValidationCells) {
                    sketchup.focusValidationCells([], '', [], []);
                  }
                });
                window.clearValidationFocusSelection = function() {
                  document.querySelectorAll('.validation-error-row.focused').forEach(function(item) {
                    item.classList.remove('focused');
                  });
                };
                window.updateValidationFocusRow = function(payload) {
                  if (!payload || !payload.rowId) return;
                  var row = document.querySelector('[data-row-id="' + String(payload.rowId).replace(/"/g, '\\"') + '"]');
                  if (!row) return;
                  var cells = Array.isArray(payload.cells) ? payload.cells : [];
                  var states = Array.isArray(payload.states) ? payload.states : [];
                  var transitions = Array.isArray(payload.transitions) ? payload.transitions : [];
                  var label = payload.label || '';
                  row.setAttribute('data-cells', cells.join(','));
                  row.setAttribute('data-states', states.join(','));
                  row.setAttribute('data-transitions', transitions.join(','));
                  var cellName = row.querySelector('.cell-name');
                  if (cellName) {
                    cellName.textContent = label;
                    cellName.setAttribute('title', label);
                  }
                };
                document.querySelectorAll('.section .filter-btn').forEach(function(button) {
                  button.addEventListener('click', function() {
                    var section = button.closest('.section');
                    if (!section) return;
                    var filter = button.getAttribute('data-filter');
                    section.querySelectorAll('.filter-btn').forEach(function(item) {
                      item.classList.remove('active');
                    });
                    button.classList.add('active');
                    section.querySelectorAll('.recheck-row').forEach(function(row) {
                      row.style.display = filter === 'all' || row.getAttribute('data-code') === filter ? '' : 'none';
                    });
                  });
                });
                document.addEventListener('dragstart', function(event) {
                  if (!event.target.closest('.cell-name, .member-value')) {
                    event.preventDefault();
                  }
                });
                document.addEventListener('keydown', function(event) {
                  if ((event.ctrlKey || event.metaKey) && String(event.key).toLowerCase() === 'a') {
                    event.preventDefault();
                    event.stopPropagation();
                  }
                }, true);
                document.addEventListener('selectionchange', function() {
                  var selection = window.getSelection && window.getSelection();
                  if (!selection || selection.rangeCount === 0) return;

                  var anchor = selection.anchorNode && selection.anchorNode.nodeType === Node.ELEMENT_NODE ?
                    selection.anchorNode :
                    selection.anchorNode && selection.anchorNode.parentElement;
                  var focus = selection.focusNode && selection.focusNode.nodeType === Node.ELEMENT_NODE ?
                    selection.focusNode :
                    selection.focusNode && selection.focusNode.parentElement;
                  var selectableTextSelector = '.cell-name, .member-value';
                  if ((anchor && anchor.closest(selectableTextSelector)) && (focus && focus.closest(selectableTextSelector))) return;

                  selection.removeAllRanges();
                });
                window.addEventListener('load', function() {
                  if (typeof sketchup !== 'undefined' && sketchup.reportDomReady) {
                    sketchup.reportDomReady();
                  }
                });
              </script>
            HTML
          end

          def format_report_distance_mm(value)
            return '-' if value.nil?

            format_report_scientific(value, 'mm')
          end

          def format_report_scientific(value, unit_html)
            text = format('%.3e', value.to_f)
            mantissa, exponent = text.split('e')
            exponent_value = exponent.to_i
            "#{html_escape(mantissa)} × 10<sup>#{html_escape(exponent_value)}</sup> #{unit_html}"
          end

          def compact_cell_pair(cells)
            first = cells[0].to_s
            second = cells[1].to_s
            return '-' if first.empty? && second.empty?

            "#{first} / #{second}"
          end

          def compact_overlap_reason(reason)
            text = reason.to_s
            return 'SketchUp Boolean에서 유효한 intersection group 미반환' if text.include?('NO_VALID_INTERSECTION_GROUP_RETURNED')
            return 'SketchUp Boolean에서 유효한 intersection 재현' if text.include?('REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION')
            return '공유면 인접 거리 허용 오차 이내' if text.include?('near-coplanar shared-face')

            text
          end

          def error_item_rows_html(rows, raw_report = nil)
            Array(rows).map { |group| error_item_card_html(group, raw_report) }.join
          end

          def error_item_card_html(group, raw_report = nil)
            code = group[:code].to_s
            recheck_row = group[:overlap_recheck]
            distance = recheck_row ? format_report_recheck_measure(recheck_row) : ''
            refs = Val3dityReportSchema.grouped_error_row_refs(group)
            occurrence = group[:count].to_i > 1 ? "<span class=\"occurrence-badge\">상세 #{group[:count].to_i}건</span>" : ''
            <<~HTML
              <details class="recheck-row validation-error-row #{error_code_color_class(code)}" data-row-id="#{html_escape(group[:id])}" data-code="#{html_escape(code)}" data-cells="#{html_escape(refs[:cells].join(','))}" data-states="#{html_escape(refs[:states].join(','))}" data-transitions="#{html_escape(refs[:transitions].join(','))}">
                <summary>
                  <span class="code-badge #{error_code_color_class(code)}">#{html_escape(code)}</span>
                  <span class="recheck-summary-main">
                    <span class="cell-name" title="#{html_escape(group[:label])}">#{html_escape(group[:label])}</span>
                    #{occurrence}
                  </span>
                  <span class="summary-distance">#{distance}</span>
                </summary>
                <div class="recheck-detail">
                  #{Array(group[:members]).each_with_index.map { |row, index| error_group_member_html(row, raw_report, index) }.join}
                </div>
              </details>
            HTML
          end

          def error_group_member_html(row, raw_report, index)
            recheck_row = matching_error_recheck_row(row, raw_report)
            raw_id = row.dig(:raw, 'id') || row.dig(:raw, :id)
            fields = [
              ['Description', row[:description]],
              ['Error ID', raw_id]
            ]
            fields.concat(overlap_member_fields(recheck_row)) if recheck_row
            <<~HTML
              <div class="error-member">
                <div class="member-heading">상세 #{index + 1}</div>
                #{fields.map { |label, value| error_member_field_html(label, value) }.join}
              </div>
            HTML
          end

          def error_member_field_html(label, value)
            return '' if value.nil? || (value.respond_to?(:empty?) && value.empty?)

            <<~HTML
              <div class="member-field">
                <span class="member-label">#{html_escape(label)}</span>
                <span class="member-value">#{html_escape(value)}</span>
              </div>
            HTML
          end

          def overlap_member_fields(row)
            [
              ['Not suppressed reason', compact_overlap_reason(row['reason'])],
              ['Overlap volume', report_measure_value(row['actual_overlap_volume_mm3'], 'mm³')]
            ]
          end

          def report_measure_value(value, unit)
            value.nil? ? nil : "#{value} #{unit}"
          end

          def matching_error_recheck_row(row, raw_report)
            code = error_code_number(row[:code])
            return nil unless [701, 704].include?(code)
            return nil unless raw_report

            cells = Val3dityReportSchema.final_error_row_refs(row, raw_report)[:cells]
            return nil if cells.length < 2

            overlap_recheck_rows(raw_report).find do |recheck_row|
              next false unless error_code_number(recheck_row['code']) == code
              next false if recheck_row['tolerated'] == true

              Val3dityReportSchema.normalize_cell_refs(recheck_row['cells']).sort == cells.sort
            end
          end

          def format_report_recheck_measure(row)
            return format_report_distance_mm(row['distance_mm']) unless row['distance_mm'].nil?
            return format_report_scientific(row['actual_overlap_volume_mm3'], 'mm<sup>3</sup>') unless row['actual_overlap_volume_mm3'].nil?

            ''
          end

          def html_escape(value)
            value.to_s
                 .gsub('&', '&amp;')
                 .gsub('<', '&lt;')
                 .gsub('>', '&gt;')
                 .gsub('"', '&quot;')
                 .gsub("'", '&#39;')
          end

          def error_code_number(code)
            Val3dityReportSchema.error_code_number(code)
          end

          def error_kind_rows(raw_report)
            Val3dityReportSchema.error_kind_rows(raw_report)
          end

          def error_item_rows(raw_report)
            Val3dityReportSchema.error_item_rows(raw_report)
          end

          def grouped_error_item_rows(raw_report)
            Val3dityReportSchema.grouped_error_item_rows(raw_report)
          end

          def error_item_label(row)
            Val3dityReportSchema.error_item_label(row)
          end

          def total_count(overview)
            Val3dityReportSchema.total_count(overview)
          end

          def valid_count(overview)
            Val3dityReportSchema.valid_count(overview)
          end

          def invalid_count(overview)
            Val3dityReportSchema.invalid_count(overview)
          end
        end

      end
    end
  end
end
