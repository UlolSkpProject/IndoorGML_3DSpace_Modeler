# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rbconfig'
require 'rexml/document'

require_relative 'val3dity_process_adapter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class Val3dityRunner
          VENDOR_ROOT = File.expand_path('../assets/vendor/val3dity-windows-x64-v2.2.0', __dir__)
          WINDOWS_ONLY_MESSAGE = 'Val3dity validity check is currently supported only on Windows because the bundled runtime is val3dity-windows-x64-v2.2.0.'
          TERMINATE_WAIT_MS      = 200
          DEFAULT_OVERLAP_TOL    = 0.5
          STRICT_OVERLAP_TOL     = -1
          OVERLAP_RECHECK_TOLERANCE = Utils::Geometry::DEFAULT_TOLERANCE
          OVERLAP_RECHECK_TOLERANCE_MM = OVERLAP_RECHECK_TOLERANCE * 25.4
          OVERLAP_RECHECK_VOLUME_TOLERANCE = OVERLAP_RECHECK_TOLERANCE**3
          OVERLAP_RECHECK_REPORT_KEY = 'indoorgml_modeler_overlap_recheck'
          STRICT_VALIDITY_KEY = 'strict_val3dity_validity'
          EXTENSION_VALIDITY_KEY = 'extension_policy_validity'
          VALIDATION_STATUS_KEY = 'indoorgml_modeler_validation_status'
          STRICT_ERRORS_REPORT_KEY = 'indoorgml_modeler_strict_errors'
          OVERLAP_RECHECK_NUMERIC_EPSILON = OVERLAP_RECHECK_TOLERANCE * 0.01

          attr_reader :report_json_path, :report_html_path

          def self.active_sessions
            @active_sessions ||= []
          end

          def self.register_session(session)
            active_sessions << session unless active_sessions.include?(session)
          end

          def self.unregister_session(session)
            active_sessions.delete(session)
          end

          def self.shutting_down?
            @shutting_down == true
          end

          def self.shutting_down!
            @shutting_down = true
          end
          def self.terminate_all(wait_ms: TERMINATE_WAIT_MS)
            active_sessions.dup.each { |session| session.terminate(wait_ms: wait_ms) }
            active_sessions.clear
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] val3dity terminate_all failed: #{e.class}: #{e.message}"
          end

          class Val3dityResult
            attr_reader :valid, :report, :report_json_path, :report_html_path, :error

            def initialize(valid:, report:, report_json_path:, report_html_path:, error: nil)
              @valid = valid
              @report = report
              @report_json_path = report_json_path
              @report_html_path = report_html_path
              @error = error
            end

            def valid?
              @valid == true
            end

            def failed?
              @valid == false && @error.nil?
            end

            def error?
              !@error.nil?
            end
          end

          def initialize(gml_path, overlap_tol: DEFAULT_OVERLAP_TOL, report_name: 'report')
            @gml_path = File.expand_path(gml_path)
            @work_dir = GmlExporter.output_root
            @report_name = sanitize_report_name(report_name)
            @report_json_path = File.join(@work_dir, "#{@report_name}.json")
            @report_dir = File.join(@work_dir, @report_name)
            @report_html_path = File.join(@report_dir, 'report.html')
            @overlap_tol = normalize_overlap_tol(overlap_tol)
          end

          def validate(progress: nil)
            raise 'Val3dityRunner#validate is deprecated. Use #start with a completion callback.'
          end

          def start(progress: nil, progress_step: :val3dity, recheck_step: :extension_recheck, report_step: :report, report_view_step: nil, &callback)
            raise ArgumentError, 'callback is required' unless callback

            ensure_supported_platform!
            ensure_runtime_files!
            FileUtils.rm_f(@report_json_path)

            progress&.running(progress_step)
            progress&.detail(
              progress_step,
              percent: 0,
              phase: '1. XSD Validation',
              message: 'Starting val3dity schema validation',
              current: File.basename(@gml_path)
            )

            args = [
              exe_path,
              @gml_path,
              '--verbose'
            ]
            args.concat(['--overlap_tol', format_tolerance(@overlap_tol)]) unless @overlap_tol.nil?
            args.concat(['-r', @report_json_path])

            session = Val3dityProcessSession.new(
              args: args,
              current_dir: VENDOR_ROOT
            )
            indoor_model = IndoorModel.current
            totals = validation_progress_totals(indoor_model)
            session.start(
              total_states: totals[:states],
              total_transitions: totals[:transitions]
            )
            self.class.register_session(session)

            completed = false

            UI.start_timer(0.1, true) do
              next false if completed

              drain_val3dity_progress(session, progress, progress_step)
              true
            end

            UI.start_timer(0.2, true) do
              next false if completed
              next true unless session.finished?

              result = nil
              exit_code = nil
              build_report_later = false
              begin
                if session.terminated?
                  result = Val3dityResult.new(
                    valid: false,
                    report: nil,
                    report_json_path: @report_json_path,
                    report_html_path: @report_html_path,
                    error: RuntimeError.new('val3dity validation was canceled.')
                  )
                else
                  session.join_reader
                  drain_val3dity_progress(session, progress, progress_step)

                  progress&.complete(progress_step)
                  exit_code = session.exit_code
                  build_report_later = true
                end
              rescue StandardError => e
                result = Val3dityResult.new(
                  valid: false,
                  report: nil,
                  report_json_path: @report_json_path,
                  report_html_path: @report_html_path,
                  error: e
                )
              ensure
                session.close
                self.class.unregister_session(session)
                completed = true
              end

              if build_report_later
                UI.start_timer(0.05, false) do
                  begin
                    result = build_result_after_process(
                      exit_code,
                      progress,
                      recheck_step: recheck_step,
                      report_step: report_step,
                      report_view_step: report_view_step
                    )
                  rescue StandardError => e
                    result = Val3dityResult.new(
                      valid: false,
                      report: nil,
                      report_json_path: @report_json_path,
                      report_html_path: @report_html_path,
                      error: e
                    )
                  end

                  callback.call(result)
                  false
                end
              else
                callback.call(result) if result
              end
              false
            end

            session
          rescue StandardError => e
            self.class.unregister_session(session) if session
            session&.close
            raise unless callback

            callback.call(
              Val3dityResult.new(
                valid: false,
                report: nil,
                report_json_path: @report_json_path,
                report_html_path: @report_html_path,
                error: e
              )
            )
          end

          private

          def normalize_overlap_tol(value)
            return nil if value.nil?

            tolerance = Float(value)
            return STRICT_OVERLAP_TOL if tolerance == STRICT_OVERLAP_TOL
            return nil if tolerance.negative?

            tolerance
          rescue ArgumentError, TypeError
            raise ArgumentError, "Invalid overlap_tol: #{value.inspect}"
          end

          def format_tolerance(value)
            format('%.15g', value.to_f)
          end

          def sanitize_report_name(value)
            name = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
            name.empty? ? 'report' : name
          end

          def validation_progress_totals(indoor_model)
            exportable_cell_spaces = indoor_model.cell_spaces.select do |cell_space|
              cell_space&.valid_sketchup_group && cell_space.duality_state&.valid?
            end
            exportable_transitions = indoor_model.transitions.select do |transition|
              transition&.valid? &&
                transition.state1&.valid? &&
                transition.state2&.valid? &&
                exportable_cell_spaces.include?(transition.state1.duality_cell) &&
                exportable_cell_spaces.include?(transition.state2.duality_cell)
            end

            {
              states: exportable_cell_spaces.length,
              transitions: exportable_transitions.length
            }
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] val3dity progress totals failed: #{e.class}: #{e.message}"
            {
              states: indoor_model.states.count(&:valid?),
              transitions: indoor_model.transitions.count(&:valid?)
            }
          end

          def ensure_supported_platform!
            raise WINDOWS_ONLY_MESSAGE unless windows?
          end

          def ensure_runtime_files!
            raise "val3dity.exe was not found:\n#{exe_path}" unless File.exist?(exe_path)
            raise "GML file was not found:\n#{@gml_path}" unless File.exist?(@gml_path)

            FileUtils.mkdir_p(@work_dir)
          end

          def drain_val3dity_progress(session, progress, progress_step)
            return unless progress

            while (payload = session.pop_progress)
              progress.detail(
                progress_step,
                percent: payload[:percent],
                phase: payload[:phase],
                message: payload[:message],
                current: payload[:current]
              )
            end
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] val3dity progress drain failed: #{e.class}: #{e.message}"
          end

          def build_result_after_process(exit_code, progress = nil, recheck_step: :extension_recheck, report_step: :report, report_view_step: nil)
            raise "val3dity failed: exit code #{exit_code}" unless exit_code == 0
            raise 'val3dity failed to create report.json.' unless File.exist?(@report_json_path)

            normalize_report_encoding

            raw_report = JSON.parse(File.read(@report_json_path, encoding: 'UTF-8'))
            preserve_strict_validation!(raw_report)
            if recheck_step
              progress&.running(recheck_step)
              progress&.detail(
                recheck_step,
                percent: 0,
                phase: 'Collect 701/704 errors',
                message: 'Rechecking val3dity 701/704 errors against exported GML geometry',
                current: File.basename(@gml_path)
              )
            end
            begin
              recheck_overlap_errors!(raw_report, progress: progress, progress_step: recheck_step)
            rescue StandardError
              progress&.fail(recheck_step) if recheck_step && progress&.respond_to?(:fail)
              raise
            end
            if recheck_step
              progress&.detail(
                recheck_step,
                percent: 100,
                phase: 'Apply extension policy',
                message: 'Extension overlap recheck finished',
                current: File.basename(@gml_path)
              )
              progress&.complete(recheck_step)
            end

            if report_step
              progress&.running(report_step)
              progress&.detail(
                report_step,
                percent: 0,
                phase: 'Report generation',
                message: 'Writing final report JSON',
                current: File.basename(@report_json_path)
              )
            end
            File.write(@report_json_path, JSON.pretty_generate(raw_report), encoding: 'UTF-8')
            if report_step
              progress&.detail(
                report_step,
                percent: 50,
                phase: 'Report generation',
                message: 'Generating report view',
                current: File.basename(@report_html_path)
              )
            end
            prepare_html_report(raw_report)
            if report_step
              progress&.detail(
                report_step,
                percent: 100,
                phase: 'Report generation',
                message: 'Report generated',
                current: File.basename(@report_html_path)
              )
              progress&.complete(report_step)
            end

            Val3dityResult.new(
              valid: raw_report['validity'] == true,
              report: raw_report,
              report_json_path: @report_json_path,
              report_html_path: @report_html_path,
              error: nil
            )
          end

          def normalize_report_encoding
            content = File.binread(@report_json_path)
            content = decode_report_content(content)
            File.write(@report_json_path, content, encoding: 'UTF-8')
          end

          def prepare_html_report(raw_report)
            FileUtils.rm_rf(@report_dir)
            FileUtils.mkdir_p(@report_dir)
            File.write(@report_html_path, fallback_report_html(raw_report), encoding: 'UTF-8')
          end

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
                  .summary-distance { color: #e8e6e0; font-family: Consolas, Monaco, monospace; font-size: 11px; text-align: right; white-space: nowrap; }
                  .summary-distance sup { font-size: 8px; line-height: 0; }
                  .recheck-detail { display: grid; gap: 6px; padding: 8px 9px 9px; }
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

          def report_metadata_line(raw_report)
            parts = [
              "val3dity #{raw_report['val3dity_version'] || 'unknown'}",
              raw_report['input_file_type'] || 'IndoorGML',
              report_checked_at(raw_report['time'])
            ].reject { |part| part.to_s.strip.empty? || part == '-' }
            <<~HTML
              <p class="report-meta-line">#{html_escape(parts.join(' · '))}</p>
            HTML
          end

          def report_error_kinds_section(raw_report)
            rows = error_kind_rows(raw_report)
            body = if rows.empty?
                     '<p class="empty">No errors.</p>'
                   else
                     <<~HTML
                       <table>
                         <thead><tr><th>Code</th><th>Error</th><th>Count</th></tr></thead>
                         <tbody>
                           #{rows.map { |row| "<tr><td><code>#{html_escape(row[:code])}</code></td><td>#{html_escape(row[:description])}</td><td>#{row[:count]}</td></tr>" }.join}
                         </tbody>
                       </table>
                     HTML
                   end
            <<~HTML
              <section class="card">
                <h2>Error 종류</h2>
                #{body}
              </section>
            HTML
          end

          def report_issue_sections(raw_report)
            [
              report_error_items_section(
                error_item_rows(raw_report),
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

          def metric_html(label, value, class_name = nil)
            value_class = ['value', class_name].compact.join(' ')
            <<~HTML
              <div class="metric">
                <div class="label">#{html_escape(label)}</div>
                <div class="#{value_class}">#{html_escape(value)}</div>
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

          def validation_status_label(raw_report)
            case raw_report[VALIDATION_STATUS_KEY]
            when 'exact_valid'
              'Exact Valid'
            when 'extension_policy_valid', 'tolerance_valid'
              'Extension Policy Valid'
            else
              'Invalid'
            end
          end

          def final_error_count(raw_report)
            error_item_rows(raw_report).length
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
                    var cells = (row.getAttribute('data-cells') || '').split(',').filter(Boolean);
                    var states = (row.getAttribute('data-states') || '').split(',').filter(Boolean);
                    var transitions = (row.getAttribute('data-transitions') || '').split(',').filter(Boolean);
                    var code = row.getAttribute('data-code') || '';
                    document.querySelectorAll('.validation-error-row.focused').forEach(function(item) {
                      item.classList.remove('focused');
                    });
                    row.classList.add('focused');
                    if ((cells.length > 0 || states.length > 0 || transitions.length > 0) && typeof sketchup !== 'undefined' && sketchup.focusValidationCells) {
                      sketchup.focusValidationCells(cells, code, states, transitions);
                    }
                  });
                });
                document.addEventListener('click', function(event) {
                  if (event.target.closest('.validation-error-row') || event.target.closest('.filter-btn')) return;
                  document.querySelectorAll('.validation-error-row.focused').forEach(function(item) {
                    item.classList.remove('focused');
                  });
                  if (typeof sketchup !== 'undefined' && sketchup.focusValidationCells) {
                    sketchup.focusValidationCells([], '', [], []);
                  }
                });
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
                  if (!event.target.closest('.cell-name')) {
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
                  if ((anchor && anchor.closest('.cell-name')) && (focus && focus.closest('.cell-name'))) return;

                  selection.removeAllRanges();
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

          def recheck_overlap_errors!(raw_report, progress: nil, progress_step: nil)
            @overlap_recheck_pair_analysis = {}
            @overlap_recheck_701_decisions = {}
            raw_report.delete(OVERLAP_RECHECK_REPORT_KEY)
            results = []
            tracker = {
              total: count_recheckable_overlap_errors(raw_report),
              processed: 0,
              progress: progress,
              progress_step: progress_step
            }
            emit_overlap_recheck_progress(
              tracker,
              message: 'Collecting val3dity 701/704 errors',
              phase: 'Collect 701/704 errors'
            )

            remove_rechecked_errors!(
              Array(raw_report['dataset_errors']),
              results,
              raw_report['input_file'],
              tracker: tracker
            )

            Array(raw_report['features']).each do |feature|
              remove_rechecked_errors!(Array(feature['errors']), results, feature['id'], tracker: tracker)
              Array(feature['primitives']).each do |primitive|
                remove_rechecked_errors!(
                  Array(primitive['errors']),
                  results,
                  feature['id'],
                  primitive['id'],
                  tracker: tracker
                )
              end
            end
            emit_overlap_recheck_progress(
              tracker,
              message: 'Applying extension validation policy',
              phase: 'Apply extension policy'
            )

            raw_report[OVERLAP_RECHECK_REPORT_KEY] = results unless results.empty?
            refresh_rechecked_validity!(raw_report)
          end

          def preserve_strict_validation!(raw_report)
            raw_report[STRICT_VALIDITY_KEY] = raw_report['validity'] == true
            raw_report[STRICT_ERRORS_REPORT_KEY] = error_item_rows(raw_report).map do |row|
              {
                'scope' => row[:scope],
                'item' => row[:item],
                'code' => row[:code],
                'description' => row[:description]
              }
            end
          end

          def count_recheckable_overlap_errors(raw_report)
            count = Array(raw_report['dataset_errors']).count { |error| recheckable_overlap_error?(error) }
            Array(raw_report['features']).each do |feature|
              count += Array(feature['errors']).count { |error| recheckable_overlap_error?(error) }
              Array(feature['primitives']).each do |primitive|
                count += Array(primitive['errors']).count { |error| recheckable_overlap_error?(error) }
              end
            end
            count
          end

          def recheckable_overlap_error?(error)
            [701, 704].include?(error_code_number(error && error['code']))
          end

          def emit_overlap_recheck_progress(tracker, result = nil, message: nil, phase: nil)
            return unless tracker && tracker[:progress] && tracker[:progress_step]

            total = tracker[:total].to_i
            processed = tracker[:processed].to_i
            percent = total.zero? ? 100 : ((processed.to_f / total) * 100).round
            cells = result ? Array(result['cells']).join(' and ') : nil
            status = result && result['status']
            default_message = if total.zero?
                                'No 701/704 errors to recheck'
                              elsif result
                                "Rechecked #{processed} / #{total} overlap errors (#{status || 'checked'})"
                              else
                                "Rechecked #{processed} / #{total} overlap errors"
                              end

            tracker[:progress].detail(
              tracker[:progress_step],
              percent: percent,
              phase: phase || 'Recheck reported cell pairs',
              message: message || default_message,
              current: cells || File.basename(@gml_path)
            )
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] overlap recheck progress failed: #{e.class}: #{e.message}"
          end

          def remove_rechecked_errors!(errors, results, *context, tracker: nil)
            errors.delete_if do |error|
              result = overlap_error_recheck_result(error, *context)
              next false unless result

              results << result
              if tracker
                tracker[:processed] = tracker[:processed].to_i + 1
                emit_overlap_recheck_progress(tracker, result)
              end
              result['tolerated'] == true
            end
          end

          def refresh_rechecked_validity!(raw_report)
            Array(raw_report['features']).each do |feature|
              Array(feature['primitives']).each do |primitive|
                primitive['validity'] = Array(primitive['errors']).empty?
              end

              feature['validity'] = Array(feature['errors']).empty? &&
                                    Array(feature['primitives']).all? { |primitive| primitive['validity'] == true }
            end

            raw_report['validity'] = error_item_rows(raw_report).empty?
            raw_report[EXTENSION_VALIDITY_KEY] = raw_report['validity'] == true
            raw_report[VALIDATION_STATUS_KEY] = if raw_report[STRICT_VALIDITY_KEY] == true
                                                  'exact_valid'
                                                elsif raw_report[EXTENSION_VALIDITY_KEY] == true
                                                  'extension_policy_valid'
                                                else
                                                  'invalid'
                                                end
            refresh_overview_counts!(raw_report, 'features_overview', Array(raw_report['features']))
            refresh_overview_counts!(
              raw_report,
              'primitives_overview',
              Array(raw_report['features']).flat_map { |feature| Array(feature['primitives']) }
            )
            raw_report['all_errors'] = error_item_rows(raw_report).map { |row| row[:code] }.uniq
          end

          def refresh_overview_counts!(raw_report, key, items)
            overview = Array(raw_report[key])
            return if overview.empty?

            overview.each do |row|
              type = row['type']
              matching = items.select { |item| type.to_s.empty? || item['type'] == type }
              row['total'] = matching.length
              row['valid'] = matching.count { |item| item['validity'] == true }
            end
          end

          def overlap_error_recheck_result(error, *context)
            code = error_code_number(error['code'])
            return nil unless [701, 704].include?(code)

            text = ([error] + context).map { |value| value.is_a?(Hash) ? value.to_json : value.to_s }.join(' ')
            cell_ids = text.scan(/cell_[A-Za-z0-9_.-]+/).uniq
            return overlap_recheck_result(code, [], false, 'cell pair not found in val3dity error') if cell_ids.length < 2

            recheck_cell_pair(code, cell_ids[0], cell_ids[1])
          end

          def recheck_cell_pair(code, cell_id1, cell_id2)
            analysis = overlap_recheck_pair_analysis(cell_id1, cell_id2)
            if analysis[:status] == :inconclusive
              return overlap_recheck_result(
                code,
                [cell_id1, cell_id2],
                false,
                analysis[:reason],
                status: 'inconclusive'
              )
            end

            decision = code == 701 ? overlap_recheck_701_decision(analysis) : overlap_recheck_704_decision(analysis)
            candidate = decision[:candidate] || {}

            overlap_recheck_result(
              code,
              [cell_id1, cell_id2],
              decision[:tolerated],
              decision[:reason],
              status: decision[:status],
              distance: candidate[:distance],
              overlap_area: candidate[:overlap_area],
              normal_thickness: decision[:normal_thickness],
              actual_overlap_volume: decision[:actual_overlap_volume],
              intersection_component_count: decision[:intersection_component_count]
            )
          end

          def overlap_recheck_pair_analysis(cell_id1, cell_id2)
            key = overlap_recheck_pair_key(cell_id1, cell_id2)
            @overlap_recheck_pair_analysis ||= {}
            @overlap_recheck_pair_analysis[key] ||= begin
              snapshot = export_geometry_snapshot
              cell1 = snapshot[cell_id1]
              cell2 = snapshot[cell_id2]
              if !(cell1 && cell2)
                {
                  status: :inconclusive,
                  cells: [cell_id1, cell_id2],
                  reason: 'GML_RECONSTRUCTION_FAILED'
                }
              elsif cell1[:unsupported] || cell2[:unsupported]
                {
                  status: :inconclusive,
                  cells: [cell_id1, cell_id2],
                  reason: 'GML_RECONSTRUCTION_FAILED'
                }
              else
                adjacency_candidates = shared_face_candidates(cell1[:faces], cell2[:faces], mode: :adjacency)
                overlap_candidates = shared_face_candidates(cell1[:faces], cell2[:faces], mode: :overlap)
                intersection = exported_solid_intersection(cell1, cell2)
                {
                  status: :ok,
                  cells: [cell_id1, cell_id2],
                  cell1: cell1,
                  cell2: cell2,
                  adjacency_candidates: adjacency_candidates,
                  overlap_candidates: overlap_candidates,
                  intersection: intersection
                }
              end
            rescue StandardError => e
              {
                status: :inconclusive,
                cells: [cell_id1, cell_id2],
                reason: "GML_RECONSTRUCTION_FAILED: #{e.class}: #{e.message}"
              }
            end
          end

          def overlap_recheck_pair_key(cell_id1, cell_id2)
            [cell_id1, cell_id2].sort.join('|')
          end

          def overlap_recheck_704_decision(analysis)
            candidate = best_overlap_recheck_candidate(analysis[:adjacency_candidates], 704)
            unless candidate
              return {
                tolerated: false,
                status: 'kept',
                reason: overlap_recheck_missing_pair_reason(704),
                candidate: nil,
                actual_overlap_volume: analysis.dig(:intersection, :volume),
                intersection_component_count: analysis.dig(:intersection, :component_count)
              }
            end

            overlap_decision = cached_701_decision(analysis)
            if overlap_decision[:status] == 'inconclusive'
              return overlap_decision.merge(
                tolerated: false,
                status: 'inconclusive',
                reason: overlap_decision[:reason],
                candidate: candidate
              )
            end
            if overlap_decision[:sketchup_intersection_reproduced]
              return {
                tolerated: false,
                status: 'kept',
                reason: 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION',
                candidate: candidate,
                actual_overlap_volume: overlap_decision[:actual_overlap_volume],
                intersection_component_count: overlap_decision[:intersection_component_count]
              }
            end

            {
              tolerated: true,
              status: 'suppressed',
              reason: overlap_recheck_tolerated_reason(704, candidate),
              candidate: candidate,
              actual_overlap_volume: overlap_decision[:actual_overlap_volume],
              intersection_component_count: overlap_decision[:intersection_component_count]
            }
          end

          def cached_701_decision(analysis)
            key = overlap_recheck_pair_key(*analysis[:cells])
            @overlap_recheck_701_decisions ||= {}
            @overlap_recheck_701_decisions[key] ||= overlap_recheck_701_decision(analysis)
          end

          def overlap_recheck_701_decision(analysis)
            intersection = analysis[:intersection]
            if intersection[:status] == :inconclusive
              return {
                tolerated: false,
                status: 'inconclusive',
                reason: intersection[:reason],
                candidate: nil,
                actual_overlap_volume: nil,
                intersection_component_count: nil,
                sketchup_intersection_reproduced: nil
              }
            end

            if intersection[:status] == :not_reproduced
              return {
                tolerated: true,
                status: 'suppressed',
                reason: 'NO_VALID_INTERSECTION_GROUP_RETURNED',
                candidate: best_overlap_recheck_candidate(analysis[:adjacency_candidates], 701),
                actual_overlap_volume: 0.0,
                intersection_component_count: 0,
                sketchup_intersection_reproduced: false
              }
            end

            {
              tolerated: false,
              status: 'kept',
              reason: 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION',
              candidate: best_overlap_recheck_candidate(analysis[:adjacency_candidates], 701),
              actual_overlap_volume: intersection[:volume],
              intersection_component_count: intersection[:component_count],
              sketchup_intersection_reproduced: true
            }
          end

          def shared_face_candidates(faces1, faces2, mode:)
            candidates = []
            faces1.each_with_index do |face1, index1|
              faces2.each_with_index do |face2, index2|
                next if !face1[:interiors].to_a.empty? || !face2[:interiors].to_a.empty?
                next unless Utils::Geometry.normals_opposite?(face1[:normal], face2[:normal])

                distance = face_pair_signed_distance(face1, face2)
                next unless distance.abs <= OVERLAP_RECHECK_TOLERANCE
                next if mode == :overlap && !distance.negative?

                overlap = coplanar_overlap_polygons(face1, face2, OVERLAP_RECHECK_TOLERANCE)
                next unless overlap[:area] > Utils::Geometry.area_tolerance(OVERLAP_RECHECK_TOLERANCE)

                candidates << {
                  face1_index: index1,
                  face2_index: index2,
                  face1: face1,
                  face2: face2,
                  distance: distance,
                  penetration_depth: [-distance, 0.0].max,
                  overlap_area: overlap[:area],
                  overlap_polygons: overlap[:polygons],
                  axis: Utils::Geometry.dominant_axis(face1[:normal]),
                  normal: face1[:normal],
                  plane1: plane_constant(face1[:normal], face1[:points].first),
                  plane2: plane_constant(face1[:normal], face2[:points].first)
                }
              end
            end
            candidates
          end

          def overlap_recheck_tolerated_reason(code, candidate)
            direction = code == 701 ? 'SketchUp Boolean non-reproduction' : 'near-coplanar shared-face adjacency'
            "#{overlap_recheck_face_pair_label(code)} face pair has signed #{direction} distance within #{OVERLAP_RECHECK_TOLERANCE_MM} mm"
          end

          def best_overlap_recheck_candidate(candidates, code)
            Array(candidates).max_by do |candidate|
              signed_score = code == 701 && candidate[:distance].to_f.negative? ? 1 : 0
              [signed_score, candidate[:overlap_area].to_f, -candidate[:distance].to_f.abs]
            end
          end

          def match_intersection_components_to_slabs(components, candidates)
            components.map do |component|
              candidates.filter_map { |candidate| component_slab_match(component, candidate) }
                        .max_by { |match| [match[:candidate][:overlap_area].to_f, -match[:normal_thickness].to_f] }
            end
          end

          def component_slab_match(component, candidate)
            samples = component[:samples]
            return nil if samples.empty?

            normal = candidate[:normal]
            normal_values = samples.map { |point| plane_constant(normal, point) }
            thickness = normal_values.max - normal_values.min
            return nil if thickness > OVERLAP_RECHECK_TOLERANCE + OVERLAP_RECHECK_NUMERIC_EPSILON

            min_plane, max_plane = [candidate[:plane1], candidate[:plane2]].minmax
            return nil unless normal_values.all? do |value|
              value >= min_plane - OVERLAP_RECHECK_NUMERIC_EPSILON &&
                value <= max_plane + OVERLAP_RECHECK_NUMERIC_EPSILON
            end

            return nil unless samples.all? do |point|
              point_inside_candidate_projection?(point, candidate)
            end

            volume_limit = (candidate[:overlap_area].to_f + Utils::Geometry.area_tolerance(OVERLAP_RECHECK_TOLERANCE)) *
                           (candidate[:penetration_depth].to_f + OVERLAP_RECHECK_NUMERIC_EPSILON)
            return nil if component[:volume].to_f > volume_limit

            { candidate: candidate, normal_thickness: thickness }
          end

          def point_inside_candidate_projection?(point, candidate)
            projected = project_point_for_axis(point, candidate[:axis])
            candidate[:overlap_polygons].any? do |polygon|
              Utils::Geometry.send(:point_in_polygon?, projected, polygon, OVERLAP_RECHECK_TOLERANCE)
            end
          end

          def coplanar_overlap_polygons(face1, face2, tolerance)
            return { area: 0.0, polygons: [] } if face1[:triangles].empty? || face2[:triangles].empty?

            axis = Utils::Geometry.dominant_axis(face1[:normal])
            polygons = []
            total_area = 0.0
            face1[:triangles].each do |triangle1|
              polygon1 = Utils::Geometry.project_points_for_axis(triangle1, axis)
              face2[:triangles].each do |triangle2|
                polygon2 = Utils::Geometry.project_points_for_axis(triangle2, axis)
                overlap = Utils::Geometry.send(:clip_polygon, polygon1, polygon2)
                next if overlap.length < 3

                area = Utils::Geometry.send(:polygon_area_2d, overlap).abs
                next if area <= Utils::Geometry.area_tolerance(tolerance)

                polygons << overlap
                total_area += area
              end
            end
            { area: total_area, polygons: polygons }
          end

          def exported_solid_intersection(cell1, cell2)
            model = Sketchup.active_model
            return { status: :inconclusive, reason: 'BOOLEAN_OPERATION_FAILED' } unless model

            started = false
            group1 = nil
            group2 = nil
            result = nil

            model.start_operation('IndoorGML overlap recheck', true)
            started = true

            group1 = build_temp_solid_group(cell1)
            group2 = build_temp_solid_group(cell2)
            return { status: :inconclusive, reason: 'GML_RECONSTRUCTION_FAILED' } unless group1 && group2
            return { status: :inconclusive, reason: 'INPUT_NOT_MANIFOLD' } unless valid_manifold_group?(group1) && valid_manifold_group?(group2)
            return { status: :inconclusive, reason: 'BOOLEAN_OPERATION_FAILED' } unless group1.respond_to?(:intersect)

            result = group1.intersect(group2)
            return { status: :not_reproduced, reason: 'NO_VALID_INTERSECTION_GROUP_RETURNED', volume: 0.0, component_count: 0 } if result.nil?

            faces = result.definition.entities.grep(Sketchup::Face).select(&:valid?)
            edges = result.definition.entities.grep(Sketchup::Edge).select(&:valid?)
            return { status: :not_reproduced, reason: 'NO_VALID_INTERSECTION_GROUP_RETURNED', volume: 0.0, component_count: 0 } if faces.empty? && edges.empty?
            return { status: :inconclusive, reason: 'INVALID_INTERSECTION_RESULT' } unless valid_manifold_group?(result)

            volume = solid_group_volume(result)
            return { status: :inconclusive, reason: 'INVALID_INTERSECTION_RESULT' } if volume.nil? || volume <= 0.0

            {
              status: :reproduced,
              reason: 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION',
              volume: volume,
              component_count: face_components(faces).length
            }
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Exported solid intersection failed: #{e.class}: #{e.message}"
            { status: :inconclusive, reason: "BOOLEAN_OPERATION_FAILED: #{e.class}: #{e.message}" }
          ensure
            model.abort_operation if started
            [result, group1, group2].compact.each do |entity|
              entity.erase! if entity.respond_to?(:valid?) && entity.valid?
            rescue StandardError
              nil
            end
          end

          def build_temp_solid_group(cell)
            group = Sketchup.active_model.entities.add_group
            cell[:faces].each do |face|
              created = group.entities.add_face(face[:points])
              unless created&.valid?
                group.erase! if group.valid?
                return nil
              end
              face[:interiors].to_a.each do |ring|
                inner = group.entities.add_face(ring)
                inner.erase! if inner&.valid?
              end
            end
            group
          end

          def valid_manifold_group?(group)
            return false unless group&.valid?
            return false unless group.respond_to?(:manifold?) && group.manifold?

            volume = solid_group_volume(group)
            !volume.nil? && volume > 0.0
          rescue StandardError
            false
          end

          def solid_group_volume(group)
            return nil unless group.respond_to?(:volume)

            volume = group.volume
            return nil if volume.nil?

            volume.to_f.abs
          rescue StandardError
            nil
          end

          def intersection_components(faces)
            face_components(faces).map do |component_faces|
              samples = intersection_component_samples(component_faces)
              {
                faces: component_faces,
                samples: samples,
                volume: component_signed_volume(component_faces).abs
              }
            end
          end

          def face_components(faces)
            remaining = faces.each_with_object({}) { |face, memo| memo[face] = true }
            components = []
            until remaining.empty?
              seed = remaining.keys.first
              stack = [seed]
              component = []
              remaining.delete(seed)
              until stack.empty?
                face = stack.pop
                component << face
                face.edges.flat_map(&:faces).uniq.each do |neighbor|
                  next unless remaining[neighbor]

                  remaining.delete(neighbor)
                  stack << neighbor
                end
              end
              components << component
            end
            components
          end

          def intersection_component_samples(faces)
            points = []
            faces.each do |face|
              face.vertices.each { |vertex| points << vertex.position }
              face.edges.each do |edge|
                vertices = edge.vertices
                next unless vertices.length == 2

                points << Geom::Point3d.new(
                  (vertices[0].position.x + vertices[1].position.x) / 2.0,
                  (vertices[0].position.y + vertices[1].position.y) / 2.0,
                  (vertices[0].position.z + vertices[1].position.z) / 2.0
                )
              end
              face_mesh_triangles_from_face(face).each do |triangle|
                points << Geom::Point3d.new(
                  triangle.map(&:x).sum / 3.0,
                  triangle.map(&:y).sum / 3.0,
                  triangle.map(&:z).sum / 3.0
                )
              end
            end
            unique_points(points)
          end

          def face_mesh_triangles_from_face(face)
            mesh = face.mesh
            points = (1..mesh.count_points).map { |index| mesh.point_at(index) }
            (1..mesh.count_polygons).flat_map do |index|
              polygon = mesh.polygon_at(index).map { |point_index| points[point_index.abs - 1] }.compact
              next [] if polygon.length < 3

              polygon.length == 3 ? [polygon] : triangulate_points(polygon)
            end
          end

          def unique_points(points)
            seen = {}
            points.each_with_object([]) do |point, unique|
              key = [point.x, point.y, point.z].map { |value| (value / OVERLAP_RECHECK_NUMERIC_EPSILON).round }.join(',')
              next if seen[key]

              seen[key] = true
              unique << point
            end
          end

          def component_signed_volume(faces)
            faces.sum do |face|
              points = face.outer_loop.vertices.map(&:position)
              next 0.0 if points.length < 3

              origin = points.first
              (1...(points.length - 1)).sum do |index|
                signed_tetrahedron_volume(origin, points[index], points[index + 1])
              end
            end
          end

          def signed_tetrahedron_volume(point1, point2, point3)
            (
              (point1.x * ((point2.y * point3.z) - (point2.z * point3.y))) -
              (point1.y * ((point2.x * point3.z) - (point2.z * point3.x))) +
              (point1.z * ((point2.x * point3.y) - (point2.y * point3.x)))
            ) / 6.0
          end

          def overlap_recheck_missing_pair_reason(code)
            "#{overlap_recheck_face_pair_label(code)} face pair not found"
          end

          def overlap_recheck_face_pair_label(_code)
            'opposite-normal'
          end

          def face_pair_signed_distance(face1, face2)
            centroid1 = face_centroid(face1)
            centroid2 = face_centroid(face2)
            return Float::INFINITY unless centroid1 && centroid2

            vector = centroid1.vector_to(centroid2)
            Utils::Geometry.dot_product(vector, face1[:normal]).to_f
          end

          def plane_constant(normal, point)
            Utils::Geometry.dot_product(
              Geom::Vector3d.new(point.x.to_f, point.y.to_f, point.z.to_f),
              normal
            ).to_f
          end

          def project_point_for_axis(point, axis)
            case axis
            when :x
              [point.y.to_f, point.z.to_f]
            when :y
              [point.x.to_f, point.z.to_f]
            else
              [point.x.to_f, point.y.to_f]
            end
          end

          def face_centroid(face)
            points = Array(face[:points])
            return nil if points.empty?

            Geom::Point3d.new(
              points.sum(&:x) / points.length.to_f,
              points.sum(&:y) / points.length.to_f,
              points.sum(&:z) / points.length.to_f
            )
          end

          def overlap_recheck_result(code, cell_ids, tolerated, reason, status: nil, distance: nil, overlap_area: nil, normal_thickness: nil, actual_overlap_volume: nil, intersection_component_count: nil)
            {
              'code' => code,
              'cells' => cell_ids,
              'tolerated' => tolerated,
              'status' => status || (tolerated ? 'suppressed' : 'kept'),
              'reason' => reason,
              'tolerance_mm' => OVERLAP_RECHECK_TOLERANCE_MM,
              'distance_mm' => distance.nil? ? nil : distance.to_f * 25.4,
              'normal_thickness_mm' => normal_thickness.nil? ? nil : normal_thickness.to_f * 25.4,
              'overlap_area_mm2' => overlap_area.nil? ? nil : overlap_area.to_f * 25.4 * 25.4,
              'actual_overlap_volume_mm3' => actual_overlap_volume.nil? ? nil : actual_overlap_volume.to_f * 25.4 * 25.4 * 25.4,
              'intersection_component_count' => intersection_component_count
            }
          end

          def error_code_number(code)
            code.to_s[/\d+/].to_i
          end

          def export_geometry_snapshot
            @export_geometry_snapshot ||= begin
              content = File.read(@gml_path, encoding: 'UTF-8')
              document = REXML::Document.new(content)
              snapshot = {}
              each_xml_element(document.root) do |element|
                next unless cell_space_element?(element)

                cell_id = xml_attribute(element, 'id')
                next if cell_id.to_s.empty?

                solid = first_descendant(element, 'Solid')
                next unless solid

                snapshot[cell_id] = parse_gml_solid_snapshot(solid, cell_id)
              end
              snapshot
            end
          end

          def cell_space_element?(element)
            %w[CellSpace GeneralSpace TransitionSpace ConnectionSpace AnchorSpace].include?(xml_local_name(element))
          end

          def parse_gml_solid_snapshot(solid, cell_id)
            faces = []
            unsupported = false
            each_xml_element(solid) do |element|
              next unless xml_local_name(element) == 'Polygon'

              face = parse_gml_polygon_face(element)
              if face[:unsupported]
                unsupported = true
              elsif face[:face]
                faces << face[:face]
              end
            end
            { id: cell_id, faces: faces, unsupported: unsupported || faces.empty? }
          end

          def parse_gml_polygon_face(polygon)
            exterior = first_child(polygon, 'exterior')
            ring = first_descendant(exterior, 'LinearRing')
            return { unsupported: true } unless ring

            points = parse_gml_ring_points(ring, polygon)
            points = remove_closing_duplicate(points)
            return { unsupported: true } if points.length < 3
            interiors = children_by_name(polygon, 'interior').filter_map do |interior|
              interior_ring = first_descendant(interior, 'LinearRing')
              next unless interior_ring

              interior_points = remove_closing_duplicate(parse_gml_ring_points(interior_ring, polygon))
              interior_points.length >= 3 ? interior_points : nil
            end

            normal = polygon_normal(points)
            return { unsupported: true } unless normal

            {
              face: {
                points: points,
                interiors: interiors,
                normal: normal,
                triangles: triangulate_points(points)
              },
              unsupported: false
            }
          end

          def parse_gml_ring_points(ring, unit_context)
            positions = []
            each_xml_element(ring) do |element|
              next unless xml_local_name(element) == 'pos'

              values = element.text.to_s.split.map(&:to_f)
              next unless values.length >= 3

              positions << gml_point_to_inches(values[0], values[1], values[2], unit_context)
            end
            positions
          end

          def gml_point_to_inches(x, y, z, element)
            factor = gml_export_unit_factor(element)
            Geom::Point3d.new(x.to_f / factor, y.to_f / factor, z.to_f / factor)
          end

          def gml_export_unit_factor(element)
            unit = nil
            current = element
            while current
              labels = xml_attribute(current, 'uomLabels')
              unit = labels.to_s.split.first unless labels.to_s.empty?
              break if unit

              srs = xml_attribute(current, 'srsName')
              unit = srs.to_s[/local-([A-Za-z]+)/, 1] unless srs.to_s.empty?
              break if unit

              current = current.respond_to?(:parent) ? current.parent : nil
            end
            case unit
            when 'ft' then 1.0 / 12.0
            when 'mm' then 25.4
            when 'cm' then 2.54
            when 'm' then 0.0254
            else 1.0
            end
          end

          def polygon_normal(points)
            x = 0.0
            y = 0.0
            z = 0.0
            points.each_with_index do |point, index|
              next_point = points[(index + 1) % points.length]
              x += (point.y - next_point.y) * (point.z + next_point.z)
              y += (point.z - next_point.z) * (point.x + next_point.x)
              z += (point.x - next_point.x) * (point.y + next_point.y)
            end
            normal = Geom::Vector3d.new(x, y, z)
            return nil if normal.length <= OVERLAP_RECHECK_NUMERIC_EPSILON

            normal.normalize!
            normal
          end

          def triangulate_points(points)
            (1...(points.length - 1)).map { |index| [points.first, points[index], points[index + 1]] }
          end

          def remove_closing_duplicate(points)
            return points if points.length < 2

            first = points.first
            last = points.last
            first.distance(last) <= OVERLAP_RECHECK_NUMERIC_EPSILON ? points[0...-1] : points
          end

          def each_xml_element(element, &block)
            return unless element

            yield element
            element.elements.each { |child| each_xml_element(child, &block) }
          end

          def first_descendant(element, local_name)
            return nil unless element

            element.elements.each do |child|
              return child if xml_local_name(child) == local_name

              found = first_descendant(child, local_name)
              return found if found
            end
            nil
          end

          def first_child(element, local_name)
            return nil unless element

            element.elements.each do |child|
              return child if xml_local_name(child) == local_name
            end
            nil
          end

          def children_by_name(element, local_name)
            return [] unless element

            children = []
            element.elements.each do |child|
              children << child if xml_local_name(child) == local_name
            end
            children
          end

          def xml_local_name(element)
            element&.name.to_s.split(':').last
          end

          def xml_attribute(element, local_name)
            return nil unless element&.respond_to?(:attributes)

            element.attributes.each_attribute do |attribute|
              name = attribute.name.to_s
              expanded_name = attribute.respond_to?(:expanded_name) ? attribute.expanded_name.to_s : name
              return attribute.value if name == local_name || name.split(':').last == local_name ||
                                        expanded_name == local_name || expanded_name.split(':').last == local_name
            end
            nil
          end

          def error_kind_rows(raw_report)
            counts = Hash.new { |hash, key| hash[key] = { code: key, description: 'UNKNOWN', count: 0 } }
            error_item_rows(raw_report).each do |row|
              item = counts[row[:code]]
              item[:description] = row[:description]
              item[:count] += 1
            end
            counts.values.sort_by { |row| row[:code].to_s }
          end

          def error_item_rows(raw_report)
            rows = []
            Array(raw_report['dataset_errors']).each do |error|
              rows << error_row('Dataset', raw_report['input_file'], error)
            end
            Array(raw_report['features']).each do |feature|
              Array(feature['errors']).each do |error|
                rows << error_row('Feature', error['id'].to_s.empty? ? feature['id'] : error['id'], error)
              end
              Array(feature['primitives']).each do |primitive|
                Array(primitive['errors']).each do |error|
                  rows << error_row('Primitive', primitive['id'], error)
                end
              end
            end
            rows
          end

          def error_row(scope, item, error)
            {
              scope: scope,
              item: item,
              code: error['code'],
              description: error['description'] || error['type'] || 'UNKNOWN',
              raw: error
            }
          end

          def error_item_rows_html(rows, raw_report = nil)
            sorted = rows.sort_by { |row| [row[:code].to_s, row[:description].to_s, error_item_label(row).to_s] }
            sorted.map { |row| error_item_card_html(row, raw_report) }.join
          end

          def error_item_card_html(row, raw_report = nil)
            code = row[:code].to_s
            recheck_row = matching_error_recheck_row(row, raw_report)
            distance = recheck_row ? format_report_recheck_measure(recheck_row) : ''
            refs = report_error_row_refs(row)
            <<~HTML
              <details class="recheck-row validation-error-row #{error_code_color_class(code)}" data-code="#{html_escape(code)}" data-cells="#{html_escape(refs[:cells].join(','))}" data-states="#{html_escape(refs[:states].join(','))}" data-transitions="#{html_escape(refs[:transitions].join(','))}">
                <summary>
                  <span class="code-badge #{error_code_color_class(code)}">#{html_escape(code)}</span>
                  <span class="recheck-summary-main">
                    <span class="cell-name" title="#{html_escape(error_item_label(row))}">#{html_escape(error_item_label(row))}</span>
                  </span>
                  <span class="summary-distance">#{distance}</span>
                </summary>
                <div class="recheck-detail">
                  <div class="reason">#{html_escape(row[:description])}</div>
                  #{recheck_row ? "<div class=\"reason\">#{html_escape(compact_overlap_reason(recheck_row['reason']))}</div>" : ''}
                </div>
              </details>
            HTML
          end

          def matching_error_recheck_row(row, raw_report)
            code = error_code_number(row[:code])
            return nil unless [701, 704].include?(code)
            return nil unless raw_report

            cells = report_error_row_refs(row)[:cells]
            return nil if cells.length < 2

            overlap_recheck_rows(raw_report).find do |recheck_row|
              next false unless error_code_number(recheck_row['code']) == code
              next false if recheck_row['tolerated'] == true

              Array(recheck_row['cells']).map(&:to_s).sort == cells.sort
            end
          end

          def format_report_recheck_measure(row)
            return format_report_distance_mm(row['distance_mm']) unless row['distance_mm'].nil?
            return format_report_scientific(row['actual_overlap_volume_mm3'], 'mm<sup>3</sup>') unless row['actual_overlap_volume_mm3'].nil?

            ''
          end

          def report_error_row_refs(row)
            text = [row[:item], row[:description], row[:raw]].map do |value|
              value.is_a?(Hash) ? value.to_json : value.to_s
            end.join(' ')
            {
              cells: text.scan(/cell_[A-Za-z0-9_.-]+/).uniq,
              states: text.scan(/state_[A-Za-z0-9_.-]+/).uniq,
              transitions: text.scan(/transition_[A-Za-z0-9_.-]+/).uniq
            }
          end

          def error_item_label(row)
            item = row[:item].to_s
            cells = item.scan(/cell_[A-Za-z0-9_.-]+/)
            return cells.uniq.join(' and ') if cells.length >= 2

            row[:scope].to_s == 'Dataset' ? item : "#{row[:scope]} #{item}"
          end

          def html_escape(value)
            value.to_s
                 .gsub('&', '&amp;')
                 .gsub('<', '&lt;')
                 .gsub('>', '&gt;')
                 .gsub('"', '&quot;')
                 .gsub("'", '&#39;')
          end

          def total_count(overview)
            Array(overview).sum { |item| item['total'].to_i }
          end

          def valid_count(overview)
            Array(overview).sum { |item| item['valid'].to_i }
          end

          def invalid_count(overview)
            total_count(overview) - valid_count(overview)
          end

          def decode_report_content(content)
            utf8 = content.dup.force_encoding('UTF-8')
            return utf8 if utf8.valid_encoding?

            content.force_encoding(report_source_encoding).encode('UTF-8')
          rescue EncodingError
            content.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
          end

          def report_source_encoding
            @report_source_encoding ||= %w[CP949 Windows-949 EUC-KR].filter_map do |name|
              Encoding.find(name)
            rescue ArgumentError
              nil
            end.first || Encoding.default_external
          end

          def exe_path
            File.join(VENDOR_ROOT, 'val3dity.exe')
          end

          def windows?
            RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/i
          end
        end

      end
    end
  end
end
