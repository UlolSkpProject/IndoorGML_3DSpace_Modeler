# frozen_string_literal: true

require_relative 'val3dity_report_schema'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class Val3dityReportRenderer
          OVERLAP_RECHECK_REPORT_KEY = Val3dityReportSchema::OVERLAP_RECHECK_REPORT_KEY
          STRICT_VALIDITY_KEY = Val3dityReportSchema::STRICT_VALIDITY_KEY
          VALIDATION_STATUS_KEY = Val3dityReportSchema::VALIDATION_STATUS_KEY
          OVERLAP_TOLERANCE_KEY = Val3dityReportSchema::OVERLAP_TOLERANCE_KEY
          ERROR_CODE_LABELS = {
            '101' => '꼭지점 개수 부족',
            '102' => '겹쳐진 인접 꼭지점',
            '103' => '닫히지 않은 모서리',
            '104' => '모서리 자기 교차',
            '201' => '모서리 간 교차',
            '202' => '중복 모서리',
            '203' => '평면 내 꼭지점 높이 편차',
            '204' => '면 뒤틀림',
            '205' => '면 내부 영역 단절',
            '206' => '내부 모서리 외곽 이탈',
            '207' => '내부 모서리 중첩',
            '208' => '내·외부 모서리 방향 동일',
            '300' => '솔리드 외곽 구성 실패',
            '301' => '솔리드 구성 면 부족',
            '302' => '닫히지 않은 솔리드',
            '303' => '모서리·꼭지점 면 접합 오류',
            '305' => '솔리드 내 연결 요소 분리',
            '306' => '솔리드 내 자기 교차',
            '307' => '솔리드 면 방향 오류',
            '401' => '솔리드 내부 경계 교차',
            '402' => '솔리드 내부 경계 중복',
            '403' => '내부 빈 공간 외곽 이탈',
            '404' => '솔리드 내부 공간 단절',
            '405' => '솔리드 면 앞뒤 방향 오류',
            '501' => '복합 솔리드 내 형상 겹침',
            '502' => '복합 솔리드 내 중복 형상',
            '503' => '복합 솔리드 내 형상 분리',
            '701' => 'CellSpace 겹침',
            '702' => 'State의 CellSpace 이탈',
            '703' => 'CellSpace·State 연결 오류',
            '704' => '공간 인접 관계·Transition 불일치',
            '901' => '입력 파일 오류',
            '902' => '비어 있는 형상',
            '903' => '검사 설정값 오류',
            '904' => '지원하지 않는 파일 형식',
            '999' => '알 수 없는 검사 오류',
            'XML_INPUT_ERROR' => 'XML 입력 오류'
          }.freeze
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
                  .result-badge.invalid, .result-badge.failed { color: #f97066; background: #351918; border: 1px solid #7a2e2a; }
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
                  .fix-attempt { flex: 0 0 auto; padding: 6px 9px; border: 1px solid #315d9b; border-radius: 6px; background: #17243b; color: #8ab4f8; cursor: pointer; font-size: 10px; font-weight: 700; white-space: nowrap; }
                  .fix-attempt:hover { background: #1d2d4a; border-color: #4278c7; }
                  .fix-attempt:disabled { cursor: default; }
                  .fix-attempt.is-pending:disabled { cursor: wait; opacity: .55; }
                  .fix-attempt.is-success:disabled { border-color: #327a4f; background: #12261a; color: #74d66f; opacity: .45; }
                  .fix-attempt.is-failure:disabled { border-color: #8b3833; background: #351918; color: #f97066; opacity: .45; }
                  .report-actions { display: flex; justify-content: flex-end; }
                  .report-action { min-width: 92px; padding: 8px 12px; border: 1px solid #5a5953; border-radius: 7px; background: #343432; color: #e8e6e0; cursor: pointer; font-size: 12px; font-weight: 700; white-space: nowrap; }
                  .report-action:hover { background: #3d3d3a; border-color: #6a6962; }
                  .recheck-list { display: grid; gap: 8px; }
                  .error-code-card { overflow: hidden; background: #222220; border: 1px solid #373633; border-radius: 9px; }
                  .error-code-card > summary { display: grid; grid-template-columns: minmax(0, 1fr) minmax(110px, 1.4fr) minmax(0, 1fr); align-items: center; gap: 8px; padding: 10px; cursor: pointer; list-style: none; }
                  .error-code-card > summary::-webkit-details-marker { display: none; }
                  .error-code-card[open] > summary { border-bottom: 1px solid #373633; }
                  .error-code-heading { grid-column: 1; display: inline-flex; align-items: center; gap: 7px; justify-self: start; min-width: 0; }
                  .error-code-heading > .toggle-triangle { flex: 0 0 auto; margin-right: 0; }
                  .error-code-label { grid-column: 2; min-width: 0; color: #b9b6ae; font-size: 10px; font-weight: 700; text-align: center; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
                  .error-code-card > summary > .bulk-fix-attempt { grid-column: 3; justify-self: end; }
                  .error-code-count { color: #85827b; font-size: 10px; font-weight: 700; }
                  .error-code-items { display: grid; gap: 7px; padding: 8px; }
                  .error-code-items .recheck-row { background: #292927; }
                  .recheck-row { background: #242422; border: 1px solid #2f2e2b; border-radius: 8px; }
                  .recheck-row.focused { border-color: #ef4444; box-shadow: inset 0 0 0 1px rgba(239, 68, 68, .55); }
                  .recheck-row.c100.focused { border-color: #f87171; box-shadow: inset 0 0 0 1px rgba(248, 113, 113, .6); }
                  .recheck-row.c200.focused { border-color: #74d66f; box-shadow: inset 0 0 0 1px rgba(116, 214, 111, .6); }
                  .recheck-row.c300.focused { border-color: #f6b45b; box-shadow: inset 0 0 0 1px rgba(246, 180, 91, .6); }
                  .recheck-row.c400.focused { border-color: #22d3ee; box-shadow: inset 0 0 0 1px rgba(34, 211, 238, .6); }
                  .recheck-row.c500.focused { border-color: #bbf7b8; box-shadow: inset 0 0 0 1px rgba(187, 247, 184, .6); }
                  .recheck-row.c700.focused { border-color: #f472b6; box-shadow: inset 0 0 0 1px rgba(244, 114, 182, .6); }
                  .recheck-row.c900.focused { border-color: #fef08a; box-shadow: inset 0 0 0 1px rgba(254, 240, 138, .6); }
                  .recheck-row summary { display: grid; grid-template-columns: auto minmax(0, 1fr) auto auto; align-items: center; gap: 8px; padding: 8px 9px; cursor: pointer; list-style: none; }
                  .validation-error-row summary { grid-template-columns: minmax(0, 1fr) auto auto; }
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
                  .validation-fix-messagebox { position: fixed; inset: 0; z-index: 2200; display: flex; align-items: center; justify-content: center; padding: 12px; background: rgba(0, 0, 0, .62); }
                  .validation-fix-messagebox[hidden] { display: none; }
                  .validation-fix-messagebox-panel { width: min(360px, 100%); max-height: calc(100vh - 24px); overflow-y: auto; padding: 14px; background: #2b2b29; border: 1px solid #4a4945; border-radius: 8px; box-shadow: 0 10px 30px rgba(0, 0, 0, .58); }
                  .validation-fix-messagebox-panel[data-variant="success"] { border-color: #327a4f; }
                  .validation-fix-messagebox-panel[data-variant="warning"] { border-color: #8a6a2f; }
                  .validation-fix-messagebox-panel[data-variant="error"] { border-color: #8b3833; }
                  .validation-fix-messagebox-title { margin: 0 0 10px; color: #e8e6e0; font-size: 14px; font-weight: 700; }
                  .validation-fix-messagebox-body { color: #b9b6ae; font-size: 12px; line-height: 1.55; white-space: pre-wrap; overflow-wrap: anywhere; user-select: text; -webkit-user-select: text; }
                  .validation-fix-messagebox-actions { display: flex; justify-content: flex-end; margin-top: 14px; }
                  .validation-fix-messagebox-close { min-width: 72px; padding: 7px 13px; border: 1px solid #315d9b; border-radius: 6px; background: #17243b; color: #dbe8ff; cursor: pointer; font-size: 12px; font-weight: 700; }
                  .validation-fix-messagebox-close:hover { background: #1d2d4a; border-color: #4278c7; }
                  .validation-fix-messagebox-close:focus-visible { outline: 2px solid #8ab4f8; outline-offset: 2px; }
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
                  <div id="validation-fix-messagebox" class="validation-fix-messagebox" role="alertdialog" aria-modal="true" aria-labelledby="validation-fix-messagebox-title" aria-describedby="validation-fix-messagebox-body" hidden>
                    <section id="validation-fix-messagebox-panel" class="validation-fix-messagebox-panel" data-variant="success">
                      <h2 id="validation-fix-messagebox-title" class="validation-fix-messagebox-title"></h2>
                      <div id="validation-fix-messagebox-body" class="validation-fix-messagebox-body"></div>
                      <div class="validation-fix-messagebox-actions">
                        <button id="validation-fix-messagebox-close" class="validation-fix-messagebox-close" type="button">확인</button>
                      </div>
                    </section>
                  </div>
                  #{report_filter_script}
                </main>
              </body>
              </html>
            HTML
          end

          def report_result_hero_section(raw_report)
            final_errors = final_error_count(raw_report)
            status = validation_status(raw_report, final_errors)
            suppressed = overlap_recheck_suppressed_count(raw_report)
            kept = overlap_recheck_kept_count(raw_report)
            inconclusive = overlap_recheck_inconclusive_count(raw_report)
            primitive_value = "#{valid_count(raw_report['primitives_overview'])} / #{total_count(raw_report['primitives_overview'])}"
            badge_class = case status
                          when 'valid' then 'result-badge valid'
                          when 'failed' then 'result-badge failed'
                          else 'result-badge invalid'
                          end
            badge_label = case status
                          when 'valid' then 'VALID'
                          when 'failed' then 'FAILED'
                          else 'INVALID'
                          end
            fix_button = status == 'invalid' ? '<button class="fix-action" type="button" onclick="if (window.sketchup && sketchup.fixValidationErrors) { sketchup.fixValidationErrors(); }">FIX</button>' : ''
            message = result_hero_message(raw_report, final_errors, suppressed, kept, inconclusive)
            <<~HTML
              <section class="hero">
                <div class="hero-top">
                  <div>
                    <div class="eyebrow">IndoorGML · val3dity #{html_escape(raw_report['val3dity_version'] || 'unknown')}</div>
                    <div class="hero-title">
                      <span class="#{badge_class}">#{badge_label}</span>
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
                <div>strict val3dity: #{html_escape(raw_report[STRICT_VALIDITY_KEY] == true ? 'valid' : 'invalid')} · final: #{html_escape(raw_report['validity'] == true ? 'valid' : 'invalid')} · features #{valid_count(raw_report['features_overview'])}/#{total_count(raw_report['features_overview'])}</div>
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
                <div class="recheck-list">
                  #{error_code_cards_html(rows, raw_report)}
                </div>
              </section>
            HTML
          end

          def report_summary_section(raw_report)
            overlap = raw_report[OVERLAP_TOLERANCE_KEY] || {}
            overlap_value = if overlap['mode'] == 'physical'
                              "#{overlap['requested_mm']} mm → #{overlap['cli_value']} #{overlap['coordinate_unit']}"
                            else
                              raw_report.dig('parameters', 'overlap_tol') || overlap['cli_value'] || '-'
                            end
            <<~HTML
              <section class="section">
                <div class="section-head">
                  <h2>파라미터</h2>
                </div>
                <div class="params-grid">
                  #{parameter_html('snap_tol', raw_report.dig('parameters', 'snap_tol') || '-')}
                  #{parameter_html('overlap_tol', overlap_value)}
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
            status = validation_status(raw_report, final_errors)
            return '최종 판정에 도달하기 전에 validation이 실패했습니다.' if status == 'failed'
            if status == 'valid'
              return 'strict val3dity 오류가 없습니다.' if raw_report[STRICT_VALIDITY_KEY] == true

              return "strict val3dity 오류는 있었지만 최종 오류가 없습니다. Overlap 재검사 후보 #{suppressed}건이 억제되었습니다."
            end
            return "실제 수정이 필요한 오류가 #{final_errors}건 남아 있습니다." if total_rechecks.zero?

            "실제 수정이 필요한 오류가 #{final_errors}건 남아 있습니다. Overlap 재검사 후보 #{total_rechecks}건 중 #{suppressed}건은 억제, #{kept}건은 유지, #{inconclusive}건은 불명확입니다."
          end

          def validation_status(raw_report, final_errors)
            status = raw_report[VALIDATION_STATUS_KEY].to_s
            return status if %w[valid invalid failed].include?(status)

            final_errors.zero? ? 'valid' : 'invalid'
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
            return 'c700' if (700..799).include?(number)
            return 'c900' if (900..999).include?(number)

            ''
          end

          def report_filter_script
            <<~HTML
              <script>
                var selectedValidationFocusRow = null;
                var pendingValidationFocusRow = null;
                var pendingValidationFocusChange = false;
                var validationFocusDeselectionInProgress = false;
                var validationFocusSelectionInProgress = false;
                var attemptedValidationFocusRow = null;
                var validationFixMessageboxPreviousFocus = null;
                var validationBulkFixAttempts = {};

                function closeValidationFixMessagebox() {
                  var dialog = document.getElementById('validation-fix-messagebox');
                  if (!dialog || dialog.hidden) return;
                  dialog.hidden = true;
                  var previousFocus = validationFixMessageboxPreviousFocus;
                  validationFixMessageboxPreviousFocus = null;
                  if (previousFocus && typeof previousFocus.focus === 'function') previousFocus.focus();
                }

                function showValidationFixMessagebox(payload) {
                  var dialog = document.getElementById('validation-fix-messagebox');
                  var panel = document.getElementById('validation-fix-messagebox-panel');
                  var title = document.getElementById('validation-fix-messagebox-title');
                  var body = document.getElementById('validation-fix-messagebox-body');
                  var closeButton = document.getElementById('validation-fix-messagebox-close');
                  if (!dialog || !panel || !title || !body || !closeButton) return false;

                  payload = payload || {};
                  var fixed = Number(payload.fixed || 0);
                  var failed = Number(payload.failed || 0);
                  var skipped = Number(payload.skipped || 0);
                  var effectiveFailed = failed + skipped;
                  panel.setAttribute('data-variant', effectiveFailed > 0 ? 'error' : (fixed > 0 ? 'success' : 'warning'));
                  title.textContent = payload.feedbackTitle || '자동 수정 결과';
                  body.textContent = payload.feedbackMessage || payload.message || '';
                  validationFixMessageboxPreviousFocus = document.activeElement;
                  dialog.hidden = false;
                  window.requestAnimationFrame(function() { closeButton.focus(); });
                  return true;
                }

                (function bindValidationFixMessagebox() {
                  var dialog = document.getElementById('validation-fix-messagebox');
                  var closeButton = document.getElementById('validation-fix-messagebox-close');
                  if (!dialog || !closeButton) return;
                  closeButton.addEventListener('click', closeValidationFixMessagebox);
                  dialog.addEventListener('click', function(event) {
                    if (event.target === dialog) closeValidationFixMessagebox();
                  });
                  document.addEventListener('keydown', function(event) {
                    if (dialog.hidden) return;
                    if (event.key === 'Escape') {
                      event.preventDefault();
                      event.stopPropagation();
                      closeValidationFixMessagebox();
                    } else if (event.key === 'Tab') {
                      event.preventDefault();
                      closeButton.focus();
                    }
                  }, true);
                })();

                function activateValidationFocusRow(row) {
                  if (!row) return;
                  var rowId = row.getAttribute('data-row-id') || '';
                  var cells = (row.getAttribute('data-cells') || '').split(',').filter(Boolean);
                  var states = (row.getAttribute('data-states') || '').split(',').filter(Boolean);
                  var transitions = (row.getAttribute('data-transitions') || '').split(',').filter(Boolean);
                  var code = row.getAttribute('data-code') || '';
                  if (typeof sketchup === 'undefined' || !sketchup.focusValidationCells) return;
                  attemptedValidationFocusRow = row;
                  validationFocusSelectionInProgress = true;
                  sketchup.focusValidationCells(cells, code, states, transitions, rowId);
                }

                function requestValidationFocusRowChange(nextRow) {
                  if (validationFocusDeselectionInProgress || validationFocusSelectionInProgress) {
                    pendingValidationFocusRow = nextRow;
                    pendingValidationFocusChange = true;
                    return;
                  }
                  if (!selectedValidationFocusRow) {
                    activateValidationFocusRow(nextRow);
                    return;
                  }

                  pendingValidationFocusRow = selectedValidationFocusRow === nextRow ? null : nextRow;
                  pendingValidationFocusChange = true;
                  validationFocusDeselectionInProgress = true;
                  if (typeof sketchup !== 'undefined' && sketchup.focusValidationCells) {
                    sketchup.focusValidationCells([], '', [], [], '');
                  } else {
                    window.completeValidationFocusRowDeselection({ok: false, message: 'Focus callback unavailable'});
                  }
                }

                function reportValidationFocusFailure(payload) {
                  var message = String((payload && payload.message) || 'Validation Focus operation failed');
                  console.warn(message);
                  if (attemptedValidationFocusRow) attemptedValidationFocusRow.title = message;
                }

                window.completeValidationFocusRowSelection = function(payload) {
                  if (!validationFocusSelectionInProgress) return;
                  var attempted = attemptedValidationFocusRow;
                  if (!attempted) return;
                  if (String(payload && payload.rowId || '') !== (attempted.getAttribute('data-row-id') || '')) return;
                  validationFocusSelectionInProgress = false;
                  attemptedValidationFocusRow = null;

                  if (payload && payload.ok === true) {
                    selectedValidationFocusRow = attempted;
                    attempted.classList.add('focused');
                    attempted.open = true;
                    if (payload.status === 'partial') {
                      var warningText = (payload.warnings || []).join('; ') || 'Partial Validation Focus';
                      attempted.title = warningText;
                      console.warn(warningText);
                    } else {
                      attempted.removeAttribute('title');
                    }
                  } else {
                    attemptedValidationFocusRow = attempted;
                    reportValidationFocusFailure(payload);
                    attemptedValidationFocusRow = null;
                  }

                  var hasPending = pendingValidationFocusChange;
                  var nextRow = pendingValidationFocusRow;
                  pendingValidationFocusRow = null;
                  pendingValidationFocusChange = false;
                  if (hasPending) requestValidationFocusRowChange(nextRow);
                };

                window.completeValidationFocusRowDeselection = function(payload) {
                  if (!validationFocusDeselectionInProgress) return;
                  validationFocusDeselectionInProgress = false;
                  if (!payload || payload.ok !== true) {
                    reportValidationFocusFailure(payload);
                    pendingValidationFocusRow = null;
                    pendingValidationFocusChange = false;
                    return; // Keep the previous focused Row. Never activate the queued Row.
                  }
                  document.querySelectorAll('.validation-error-row.focused').forEach(function(item) {
                    item.classList.remove('focused');
                    item.open = false;
                  });
                  selectedValidationFocusRow = null;
                  var nextRow = pendingValidationFocusRow;
                  pendingValidationFocusRow = null;
                  pendingValidationFocusChange = false;
                  activateValidationFocusRow(nextRow);
                };

                document.querySelectorAll('.validation-error-row').forEach(function(row) {
                  var summary = row.querySelector(':scope > summary');
                  if (!summary) return;
                  summary.addEventListener('click', function(event) {
                    event.preventDefault();
                    event.stopPropagation();
                    requestValidationFocusRowChange(row);
                  });
                });

                function beginValidationFixAttempt(button, code, rowId) {
                  if (!button || button.disabled) return;
                  button.disabled = true;
                  button.classList.remove('is-success', 'is-failure');
                  button.classList.add('is-pending');
                  button.textContent = '처리 중';
                  updateBulkFixButtonState(code);
                  if (typeof sketchup !== 'undefined' && sketchup.attemptValidationFix) {
                    sketchup.attemptValidationFix(code, rowId);
                  } else {
                    button.disabled = false;
                    button.classList.remove('is-pending');
                    button.textContent = '수정 시도';
                    updateBulkFixButtonState(code);
                  }
                }

                function completeValidationFixButton(button, payload) {
                  if (!button) return false;
                  var fixed = Number(payload.fixed || 0);
                  var skipped = Number(payload.skipped || 0);
                  var failed = Number(payload.failed || 0);
                  var succeeded = fixed > 0 && skipped === 0 && failed === 0;
                  button.classList.remove('is-pending', 'is-success', 'is-failure');
                  button.classList.add(succeeded ? 'is-success' : 'is-failure');
                  button.disabled = true;
                  button.textContent = succeeded ? '성공' : '실패';
                  button.title = payload.message || '';
                  updateBulkFixButtonState(button.getAttribute('data-code') || '');
                  return succeeded;
                }

                function validationFixFailureReasons(payload) {
                  var countPattern = /^성공\\s+\\d+건\\s*\\/\\s*실패\\s+\\d+건$/;
                  var lines = String(payload.feedbackMessage || '').split(/\\r?\\n/).map(function(line) {
                    return line.trim();
                  }).filter(function(line) {
                    return line && !countPattern.test(line);
                  });
                  if (lines.length === 0) {
                    lines = Array.isArray(payload.details) ? payload.details.map(String).filter(Boolean) : [];
                  }
                  if (lines.length === 0) {
                    var message = String(payload.message || '').trim();
                    if (message && !countPattern.test(message)) lines.push(message);
                  }
                  return lines.filter(function(line, index) { return lines.indexOf(line) === index; });
                }

                function completeValidationBulkFixAttempt(payload, succeeded) {
                  var code = String(payload.code || '');
                  var rowId = String(payload.rowId || '');
                  var attempt = validationBulkFixAttempts[code];
                  if (!attempt || !rowId || attempt.pending[rowId] !== true) return false;

                  delete attempt.pending[rowId];
                  if (succeeded) {
                    attempt.success += 1;
                  } else {
                    attempt.failure += 1;
                    var reasons = validationFixFailureReasons(payload);
                    var reason = reasons.length > 0 ? reasons.join(' / ') : '수정하지 못했습니다.';
                    var label = attempt.labels[rowId] || '대상 요소';
                    attempt.failureReasons.push(label + ': ' + reason);
                  }
                  if (Object.keys(attempt.pending).length > 0) return true;

                  delete validationBulkFixAttempts[code];
                  var feedbackLines = ['성공 ' + attempt.success + '건 / 실패 ' + attempt.failure + '건'];
                  attempt.failureReasons.forEach(function(reason) {
                    feedbackLines.push('• ' + reason);
                  });
                  var aggregate = {
                    code: code,
                    rowId: '',
                    bulk: true,
                    fixed: attempt.success,
                    skipped: 0,
                    failed: attempt.failure,
                    message: '성공 ' + attempt.success + '건 / 실패 ' + attempt.failure + '건',
                    feedbackTitle: attempt.failure > 0 ? '자동 수정 실패' : '자동 수정 성공',
                    feedbackMessage: feedbackLines.join('\\n')
                  };
                  console.log(aggregate.message);
                  showValidationFixMessagebox(aggregate);
                  return true;
                }

                function updateBulkFixButtonState(code) {
                  var selector = '.error-code-card[data-code="' + String(code).replace(/"/g, '\\"') + '"]';
                  var card = document.querySelector(selector);
                  if (!card) return;
                  var bulkButton = card.querySelector(':scope > summary .bulk-fix-attempt');
                  if (!bulkButton) return;
                  var rowButtons = Array.prototype.slice.call(card.querySelectorAll('.row-fix-attempt'));
                  var hasAvailable = rowButtons.some(function(button) { return !button.disabled; });
                  bulkButton.classList.remove('is-pending', 'is-success', 'is-failure');
                  if (hasAvailable) {
                    bulkButton.disabled = false;
                    bulkButton.textContent = '일괄 수정 시도';
                    return;
                  }

                  bulkButton.disabled = true;
                  if (rowButtons.some(function(button) { return button.classList.contains('is-pending'); })) {
                    bulkButton.classList.add('is-pending');
                    bulkButton.textContent = '처리 중';
                    return;
                  }

                  var succeeded = rowButtons.length > 0 && rowButtons.every(function(button) {
                    return button.classList.contains('is-success');
                  });
                  bulkButton.classList.add(succeeded ? 'is-success' : 'is-failure');
                  bulkButton.textContent = succeeded ? '성공' : '실패';
                }

                document.querySelectorAll('.row-fix-attempt').forEach(function(button) {
                  button.addEventListener('click', function(event) {
                    event.preventDefault();
                    event.stopPropagation();
                    var rowId = button.getAttribute('data-row-id') || '';
                    var code = button.getAttribute('data-code') || '';
                    beginValidationFixAttempt(button, code, rowId);
                  });
                });
                document.querySelectorAll('.bulk-fix-attempt').forEach(function(button) {
                  button.addEventListener('click', function(event) {
                    event.preventDefault();
                    event.stopPropagation();
                    var card = button.closest('.error-code-card');
                    if (!card) return;
                    var code = button.getAttribute('data-code') || '';
                    var rowButtons = Array.prototype.slice.call(card.querySelectorAll('.row-fix-attempt:not(:disabled)'));
                    var pending = {};
                    var labels = {};
                    rowButtons.forEach(function(rowButton) {
                      var rowId = rowButton.getAttribute('data-row-id') || '';
                      var row = rowButton.closest('.validation-error-row');
                      var cellName = row && row.querySelector('.cell-name');
                      pending[rowId] = true;
                      labels[rowId] = cellName ? cellName.textContent.trim() : '대상 요소';
                    });
                    validationBulkFixAttempts[code] = {
                      pending: pending,
                      labels: labels,
                      success: 0,
                      failure: 0,
                      failureReasons: []
                    };
                    rowButtons.forEach(function(rowButton) {
                      rowButton.click();
                    });
                  });
                });
                window.completeValidationFixAttempt = function(payload) {
                  payload = payload || {};
                  var rowId = String(payload.rowId || '');
                  var code = String(payload.code || '');
                  var selector = rowId ?
                    '.row-fix-attempt[data-row-id="' + rowId.replace(/"/g, '\\"') + '"]' :
                    '.bulk-fix-attempt[data-code="' + code.replace(/"/g, '\\"') + '"]';
                  var succeeded = false;
                  document.querySelectorAll(selector).forEach(function(button) {
                    succeeded = completeValidationFixButton(button, payload);
                  });
                  console.log(payload.message || 'validation fix attempt completed');
                  if (!completeValidationBulkFixAttempt(payload, succeeded)) {
                    showValidationFixMessagebox(payload);
                  }
                };
                document.querySelectorAll('.bulk-fix-attempt').forEach(function(button) {
                  updateBulkFixButtonState(button.getAttribute('data-code') || '');
                });
                document.addEventListener('click', function(event) {
                  if (event.target.closest('.validation-fix-messagebox') || event.target.closest('.validation-error-row') || event.target.closest('.filter-btn') || event.target.closest('.fix-attempt')) return;
                  requestValidationFocusRowChange(null);
                });
                window.clearValidationFocusSelection = function() {
                  selectedValidationFocusRow = null;
                  pendingValidationFocusRow = null;
                  pendingValidationFocusChange = false;
                  attemptedValidationFocusRow = null;
                  validationFocusSelectionInProgress = false;
                  validationFocusDeselectionInProgress = false;
                  document.querySelectorAll('.validation-error-row.focused').forEach(function(item) {
                    item.classList.remove('focused');
                    item.open = false;
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
            return '체적 없이 공유 경계에서만 접촉' if text.include?('BOUNDARY_CONTACT_ONLY')
            return 'SketchUp Boolean 교차 결과 판정 불가' if text.include?('BOOLEAN_INTERSECTION_INCONCLUSIVE')
            return '공유면 인접 거리 허용 오차 이내' if text.include?('near-coplanar shared-face')

            text
          end

          def error_code_cards_html(rows, raw_report = nil)
            Array(rows)
              .group_by { |group| report_row_code(group) }
              .sort_by { |code, _groups| [error_code_number(code), code.to_s] }
              .map { |code, groups| error_code_card_html(code, groups, raw_report) }
              .join
          end

          def error_code_card_html(code, groups, raw_report = nil)
            color_class = error_code_color_class(code)
            code_label = error_code_label(code)
            bulk_fix_attempt = if auto_fix_supported_code?(code)
                                 <<~HTML.chomp
                                   <button class="fix-attempt bulk-fix-attempt" type="button" data-code="#{html_escape(code)}">일괄 수정 시도</button>
                                 HTML
                               else
                                 ''
                               end
            <<~HTML
              <details class="error-code-card #{color_class}" data-code="#{html_escape(code)}">
                <summary>
                  <span class="error-code-heading">
                    <span class="toggle-triangle" aria-hidden="true"></span>
                    <span class="code-badge #{color_class}">#{html_escape(code)}</span>
                    <span class="error-code-count">#{groups.length}건</span>
                  </span>
                  <span class="error-code-label" title="#{html_escape(code_label)}">#{html_escape(code_label)}</span>
                  #{bulk_fix_attempt}
                </summary>
                <div class="error-code-items">
                  #{Array(groups).map { |group| error_item_card_html(group, raw_report) }.join}
                </div>
              </details>
            HTML
          end

          def error_code_label(code)
            ERROR_CODE_LABELS.fetch(code.to_s, '검사 오류')
          end

          def error_item_card_html(group, raw_report = nil)
            code = group[:code].to_s
            recheck_row = group[:overlap_recheck]
            distance = recheck_row ? format_report_recheck_measure(recheck_row) : ''
            refs = Val3dityReportSchema.grouped_error_row_refs(group)
            occurrence = group[:count].to_i > 1 ? "<span class=\"occurrence-badge\">상세 #{group[:count].to_i}건</span>" : ''
            fix_attempt = if auto_fix_supported_code?(code)
                            <<~HTML.chomp
                              <button class="fix-attempt row-fix-attempt" type="button" data-row-id="#{html_escape(group[:id])}" data-code="#{html_escape(code)}">수정 시도</button>
                            HTML
                          else
                            ''
                          end
            <<~HTML
              <details class="recheck-row validation-error-row #{error_code_color_class(code)}" data-row-id="#{html_escape(group[:id])}" data-code="#{html_escape(code)}" data-cells="#{html_escape(refs[:cells].join(','))}" data-states="#{html_escape(refs[:states].join(','))}" data-transitions="#{html_escape(refs[:transitions].join(','))}">
                <summary>
                  <span class="recheck-summary-main">
                    <span class="cell-name" title="#{html_escape(group[:label])}">#{html_escape(group[:label])}</span>
                    #{occurrence}
                  </span>
                  <span class="summary-distance">#{distance}</span>
                  #{fix_attempt}
                </summary>
                <div class="recheck-detail">
                  #{Array(group[:members]).each_with_index.map { |row, index| error_group_member_html(row, raw_report, index) }.join}
                </div>
              </details>
            HTML
          end

          def auto_fix_supported_code?(code)
            Val3dityReportSchema::AUTO_FIX_SUPPORTED_CODES.include?(error_code_number(code))
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
