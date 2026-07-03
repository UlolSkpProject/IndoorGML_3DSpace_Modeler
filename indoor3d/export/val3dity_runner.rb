# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rbconfig'

require_relative 'val3dity_process_adapter'
require_relative 'val3dity_report_schema'
require_relative 'val3dity_report_renderer'
require_relative 'val3dity_overlap_recheck_policy'
require_relative 'val3dity_exported_solid_snapshot_reader'
require_relative 'val3dity_overlap_geometry_rechecker'
require_relative 'val3dity_run_orchestration'

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
          OVERLAP_RECHECK_NUMERIC_EPSILON = OVERLAP_RECHECK_TOLERANCE * 0.01

          attr_reader :report_json_path, :report_html_path

          def self.active_sessions
            @active_sessions ||= []
          end

          def self.session_owner_keys
            @session_owner_keys ||= {}
          end

          def self.owner_key_for_model(model)
            model&.object_id
          rescue StandardError
            nil
          end

          def self.default_owner_key
            return nil unless defined?(Sketchup)

            owner_key_for_model(Sketchup.active_model)
          rescue StandardError
            nil
          end

          def self.register_session(session, owner_key: nil)
            active_sessions << session unless active_sessions.include?(session)
            session_owner_keys[session] = owner_key
          end

          def self.unregister_session(session)
            active_sessions.delete(session)
            session_owner_keys.delete(session)
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
            session_owner_keys.clear
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] val3dity terminate_all failed: #{e.class}: #{e.message}"
          end

          def self.terminate_for_model(model, wait_ms: TERMINATE_WAIT_MS)
            terminate_for_owner(owner_key_for_model(model), wait_ms: wait_ms)
          end

          def self.terminate_for_owner(owner_key, wait_ms: TERMINATE_WAIT_MS)
            return if owner_key.nil?

            session_owner_keys.dup.each do |session, session_owner_key|
              next unless session_owner_key == owner_key

              session.terminate(wait_ms: wait_ms)
              unregister_session(session)
            end
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] val3dity terminate_for_owner failed: #{e.class}: #{e.message}"
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

            def error?
              !@error.nil?
            end
          end

          def initialize(gml_path, overlap_tol: DEFAULT_OVERLAP_TOL, report_name: 'report', indoor_model: nil, owner_key: nil)
            @gml_path = File.expand_path(gml_path)
            @work_dir = GmlExporter.output_root
            @report_name = sanitize_report_name(report_name)
            @report_json_path = File.join(@work_dir, "#{@report_name}.json")
            @report_dir = File.join(@work_dir, @report_name)
            @report_html_path = File.join(@report_dir, 'report.html')
            @overlap_tol = normalize_overlap_tol(overlap_tol)
            @indoor_model = indoor_model
            @owner_key = owner_key || self.class.owner_key_for_model(indoor_model&.model) || self.class.default_owner_key
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

            session = Val3dityProcessAdapter.new(
              args: args,
              current_dir: VENDOR_ROOT
            )
            indoor_model = @indoor_model || IndoorModel.current
            totals = validation_progress_totals(indoor_model)
            session.start(
              total_states: totals[:states],
              total_transitions: totals[:transitions]
            )

            Val3dityRunOrchestration.new(
              session: session,
              progress: progress,
              progress_step: progress_step,
              callback: callback,
              register_session: ->(active_session) { self.class.register_session(active_session, owner_key: @owner_key) },
              unregister_session: ->(active_session) { self.class.unregister_session(active_session) },
              drain_progress: ->(active_session, active_progress, active_step) { drain_val3dity_progress(active_session, active_progress, active_step) },
              build_result: lambda { |exit_code|
                build_result_after_process(
                  exit_code,
                  progress,
                  recheck_step: recheck_step,
                  report_step: report_step,
                  report_view_step: report_view_step
                )
              },
              error_result: ->(error) { error_result(error) }
            ).start
          rescue StandardError => e
            self.class.unregister_session(session) if session
            session&.close
            raise unless callback

            callback.call(error_result(e))
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

          def error_result(error)
            Val3dityResult.new(
              valid: false,
              report: nil,
              report_json_path: @report_json_path,
              report_html_path: @report_html_path,
              error: error
            )
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
            File.write(@report_html_path, Val3dityReportRenderer.new.render(raw_report), encoding: 'UTF-8')
          end

          def recheck_overlap_errors!(raw_report, progress: nil, progress_step: nil)
            @overlap_recheck_pair_analysis = {}
            @overlap_recheck_701_decisions = {}
            tracker = {
              total: overlap_recheck_policy.count_recheckable_errors(raw_report),
              processed: 0,
              progress: progress,
              progress_step: progress_step
            }
            emit_overlap_recheck_progress(
              tracker,
              message: 'Collecting val3dity 701/704 errors',
              phase: 'Collect 701/704 errors'
            )

            overlap_recheck_policy.apply!(
              raw_report,
              on_result: lambda { |result|
                tracker[:processed] = tracker[:processed].to_i + 1
                emit_overlap_recheck_progress(tracker, result)
              },
              before_refresh: lambda { |_results|
                emit_overlap_recheck_progress(
                  tracker,
                  message: 'Applying extension validation policy',
                  phase: 'Apply extension policy'
                )
              }
            ) { |code, cell_id1, cell_id2| recheck_cell_pair(code, cell_id1, cell_id2) }
          end

          def preserve_strict_validation!(raw_report)
            overlap_recheck_policy.preserve_strict_validation!(raw_report)
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
            overlap_geometry_rechecker.pair_analysis(cell_id1, cell_id2)
          end

          def overlap_recheck_704_decision(analysis)
            candidate = overlap_geometry_rechecker.best_candidate(analysis[:adjacency_candidates], 704)
            unless candidate
              return {
                tolerated: false,
                status: 'kept',
                reason: overlap_geometry_rechecker.missing_pair_reason(704),
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
              reason: overlap_geometry_rechecker.tolerated_reason(704, candidate),
              candidate: candidate,
              actual_overlap_volume: overlap_decision[:actual_overlap_volume],
              intersection_component_count: overlap_decision[:intersection_component_count]
            }
          end

          def cached_701_decision(analysis)
            key = analysis[:cells].sort.join('|')
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
                candidate: overlap_geometry_rechecker.best_candidate(analysis[:adjacency_candidates], 701),
                actual_overlap_volume: 0.0,
                intersection_component_count: 0,
                sketchup_intersection_reproduced: false
              }
            end

            {
              tolerated: false,
              status: 'kept',
              reason: 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION',
              candidate: overlap_geometry_rechecker.best_candidate(analysis[:adjacency_candidates], 701),
              actual_overlap_volume: intersection[:volume],
              intersection_component_count: intersection[:component_count],
              sketchup_intersection_reproduced: true
            }
          end

          def overlap_recheck_result(code, cell_ids, tolerated, reason, status: nil, distance: nil, overlap_area: nil, normal_thickness: nil, actual_overlap_volume: nil, intersection_component_count: nil)
            overlap_recheck_policy.recheck_result(
              code,
              cell_ids,
              tolerated,
              reason,
              status: status,
              distance: distance,
              overlap_area: overlap_area,
              normal_thickness: normal_thickness,
              actual_overlap_volume: actual_overlap_volume,
              intersection_component_count: intersection_component_count
            )
          end

          def overlap_recheck_policy
            @overlap_recheck_policy ||= Val3dityOverlapRecheckPolicy.new(
              tolerance_mm: OVERLAP_RECHECK_TOLERANCE_MM
            )
          end

          def overlap_geometry_rechecker
            @overlap_geometry_rechecker ||= Val3dityOverlapGeometryRechecker.new(
              snapshot_reader: Val3dityExportedSolidSnapshotReader.new(
                @gml_path,
                numeric_epsilon: OVERLAP_RECHECK_NUMERIC_EPSILON
              ),
              tolerance: OVERLAP_RECHECK_TOLERANCE,
              logger: IndoorCore::Logger
            )
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
