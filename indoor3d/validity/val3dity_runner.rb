# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rbconfig'

require_relative 'val3dity_process_adapter'
require_relative 'val3dity_report_schema'
require_relative 'val3dity_report_renderer'
require_relative 'val3dity_overlap_recheck_policy'
require_relative 'val3dity_full_intersection_rechecker'
require_relative 'validity_native_bridge'
require_relative 'val3dity_run_orchestration'
require_relative 'xml_input_validator'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class Val3dityRunner
          VENDOR_ROOT = File.expand_path('../assets/vendor/val3dity-windows-x64-v2.2.0', __dir__)
          WINDOWS_ONLY_MESSAGE = 'Val3dity validity check is currently supported only on Windows because the bundled runtime is val3dity-windows-x64-v2.2.0.'
          TERMINATE_WAIT_MS      = 200
          STRICT_OVERLAP_TOL     = -1
          DEFAULT_OVERLAP_TOL    = STRICT_OVERLAP_TOL
          OVERLAP_RECHECK_TOLERANCE = Utils::Geometry::VALIDATION_TOLERANCE
          OVERLAP_RECHECK_TOLERANCE_MM = OVERLAP_RECHECK_TOLERANCE * 25.4

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

            def outcome
              return :failed if error?

              status = @report&.[](Val3dityReportSchema::VALIDATION_STATUS_KEY).to_s
              return :valid if status == 'valid'
              return :valid if status.empty? && valid?

              :invalid
            end

            def failed?
              outcome == :failed
            end

            def invalid?
              outcome == :invalid
            end
          end

          def initialize(gml_path, overlap_tol: DEFAULT_OVERLAP_TOL, overlap_tol_mm: nil,
                         report_name: 'report', work_dir: nil, indoor_model: nil, owner_key: nil)
            @gml_path = File.expand_path(gml_path)
            @work_dir = File.expand_path(work_dir || GmlExporter.output_root)
            @report_name = sanitize_report_name(report_name)
            @report_json_path = File.join(@work_dir, "#{@report_name}.json")
            @report_dir = File.join(@work_dir, @report_name)
            @report_html_path = File.join(@report_dir, 'report.html')
            @indoor_model = indoor_model
            @model = indoor_model&.model
            @overlap_tol_mm = normalize_overlap_tol_mm(overlap_tol_mm)
            @overlap_tol = if @overlap_tol_mm.nil?
                             normalize_overlap_tol(overlap_tol)
                           else
                             raise ArgumentError, 'overlap_tol_mm requires an indoor_model with a model.' unless @model

                             GmlExporter.millimeters_to_coordinate_units(@overlap_tol_mm, model: @model)
                           end
            @owner_key = owner_key || self.class.owner_key_for_model(indoor_model&.model) || self.class.default_owner_key
          end

          def start(progress: nil, progress_step: :val3dity, recheck_step: :extension_recheck,
                    report_step: :report, active: nil, &callback)
            raise ArgumentError, 'callback is required' unless callback

            ensure_supported_platform!
            ensure_runtime_files!
            FileUtils.rm_f(@report_json_path)

            progress&.running(progress_step)
            progress&.detail(
              progress_step,
              percent: 0,
              phase: '1. Input Parsing',
              message: 'Checking XML well-formedness (XSD validation is not performed)',
              current: File.basename(@gml_path)
            )
            input_result = XmlInputValidator.new.validate(@gml_path)
            unless input_result.valid?
              progress&.fail(progress_step)
              result = build_preflight_invalid_result(
                input_result.errors,
                progress: progress,
                report_step: report_step
              )
              callback.call(result)
              return nil
            end
            progress&.detail(
              progress_step,
              percent: 2,
              phase: '1. Input Parsing',
              message: 'XML input parsed successfully; starting val3dity',
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
                  report_step: report_step
                )
              },
              error_result: ->(error) { error_result(error) },
              active: active
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

          def normalize_overlap_tol_mm(value)
            return nil if value.nil?

            tolerance = Float(value)
            raise ArgumentError if tolerance.negative?

            tolerance
          rescue ArgumentError, TypeError
            raise ArgumentError, "Invalid overlap_tol_mm: #{value.inspect}"
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

          def build_result_after_process(exit_code, progress = nil, recheck_step: :extension_recheck,
                                         report_step: :report)
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
                phase: 'Apply recheck policy',
                message: 'Overlap recheck finished',
                current: File.basename(@gml_path)
              )
              progress&.complete(recheck_step)
            end

            attach_overlap_tolerance_metadata!(raw_report)

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

          def build_preflight_invalid_result(errors, progress:, report_step:)
            raw_report = {
              'input_file' => File.basename(@gml_path),
              'validity' => false,
              'val3dity_version' => 'not run',
              'parameters' => {},
              'dataset_errors' => Array(errors),
              'features' => [],
              'features_overview' => [],
              'primitives_overview' => [],
              Val3dityReportSchema::STRICT_VALIDITY_KEY => false,
              Val3dityReportSchema::VALIDATION_STATUS_KEY => 'invalid'
            }
            attach_overlap_tolerance_metadata!(raw_report)
            write_report(raw_report, progress: progress, report_step: report_step)
            Val3dityResult.new(
              valid: false,
              report: raw_report,
              report_json_path: @report_json_path,
              report_html_path: @report_html_path,
              error: nil
            )
          end

          def attach_overlap_tolerance_metadata!(raw_report)
            unit = GmlExporter.coordinate_unit_for_model(@model)
            raw_report[Val3dityReportSchema::OVERLAP_TOLERANCE_KEY] = {
              'mode' => @overlap_tol_mm.nil? ? (@overlap_tol == STRICT_OVERLAP_TOL ? 'strict' : 'coordinate') : 'physical',
              'requested_mm' => @overlap_tol_mm,
              'cli_value' => @overlap_tol,
              'coordinate_unit' => unit[:unit]
            }
          end

          def write_report(raw_report, progress:, report_step:)
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
          end

          def recheck_overlap_errors!(raw_report, progress: nil, progress_step: nil)
            requests = overlap_recheck_policy.recheck_requests(raw_report)
            prepare_validity_recheck_batch(requests)

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
                  message: 'Applying overlap recheck policy',
                  phase: 'Apply recheck policy'
                )
              }
            ) { |code, cell_id1, cell_id2| recheck_cell_pair(code, cell_id1, cell_id2) }
          ensure
            @validity_native_results = nil
            @validity_core_704_results = nil
            @validity_native_ran = false
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

          def prepare_validity_recheck_batch(requests)
            @validity_native_results = {}
            @validity_core_704_results = {}
            @validity_native_ran = false
            return if Array(requests).empty?

            entries = validation_snapshot_entries(requests)
            return if entries.empty?

            snapshots = entries.map { |entry| entry.fetch(:snapshot) }
            keys = entries.map { |entry| entry.fetch(:report_id) }
            index_by_id = keys.each_with_index.to_h
            native_requests = Array(requests).filter_map do |request|
              cells = Array(request[:cells])
              first = index_by_id[cells[0]]
              second = index_by_id[cells[1]]
              next if first.nil? || second.nil?

              {
                first: [first, second].min,
                second: [first, second].max,
                code: request[:code].to_i
              }
            end

            if ValidityNativeBridge.available?
              begin
                batch = ValidityNativeBridge.compute(
                  snapshots,
                  native_requests,
                  overlap_tolerance: OVERLAP_RECHECK_TOLERANCE
                )
                Array(batch[:results]).each do |result|
                  first_id = keys.fetch(result[:first])
                  second_id = keys.fetch(result[:second])
                  @validity_native_results[
                    validity_result_key(result[:code], first_id, second_id)
                  ] = result
                end
                @validity_native_ran = true
                return
              rescue StandardError => e
                IndoorCore::Logger.puts(
                  "[IndoorGML] Native validity batch failed; using conservative compatibility paths: " \
                  "#{e.class}: #{e.message}"
                )
              end
            end

            prepare_core_704_compatibility_results(
              requests,
              snapshots,
              keys,
              index_by_id
            )
          end

          def validation_snapshot_entries(requests)
            indoor_model = @indoor_model || IndoorModel.current
            seen = {}
            Array(requests).flat_map { |request| Array(request[:cells]) }.filter_map do |report_id|
              next if seen[report_id]

              seen[report_id] = true
              cell_space = indoor_model&.find_cell_space_by_normalized_id(report_id)
              next unless cell_space&.valid?

              group = cell_space.valid_sketchup_group
              next unless group&.valid?

              snapshot = Utils::Geometry.adjacency_snapshot(group)
              next unless snapshot

              {
                report_id: report_id,
                cell_space: cell_space,
                snapshot: snapshot
              }.freeze
            end
          end

          def prepare_core_704_compatibility_results(
            requests,
            snapshots,
            keys,
            index_by_id
          )
            requested_704 = Array(requests).select { |request| request[:code].to_i == 704 }
            return if requested_704.empty?
            return unless NativeAdjacencyBridge.available?

            result = NativeAdjacencyBridge.compute(
              snapshots,
              tolerance: OVERLAP_RECHECK_TOLERANCE,
              keys: keys
            )
            adjacent = Array(result[:pair_results]).each_with_object({}) do |pair, out|
              out[[pair[0].to_i, pair[1].to_i]] = pair[2]
            end

            requested_704.each do |request|
              cells = Array(request[:cells])
              first = index_by_id[cells[0]]
              second = index_by_id[cells[1]]
              next if first.nil? || second.nil?

              pair = [[first, second].min, [first, second].max]
              axis = adjacent[pair]
              @validity_core_704_results[
                validity_result_key(704, cells[0], cells[1])
              ] = {
                status: axis ? :adjacent : :not_adjacent,
                axis: axis
              }.freeze
            end
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Core Native 704 compatibility check failed: #{e.class}: #{e.message}"
            )
          end

          def recheck_cell_pair(code, cell_id1, cell_id2)
            if code.to_i == 701
              recheck_701_cell_pair(cell_id1, cell_id2)
            else
              recheck_704_cell_pair(cell_id1, cell_id2)
            end
          end

          def recheck_701_cell_pair(cell_id1, cell_id2)
            result = @validity_native_results &&
              @validity_native_results[validity_result_key(701, cell_id1, cell_id2)]

            case result && result[:status]
            when :no_overlap
              return overlap_recheck_result(
                701,
                [cell_id1, cell_id2],
                true,
                'NATIVE_NO_POSITIVE_VOLUME_INTERSECTION',
                status: 'suppressed',
                actual_overlap_volume: 0.0,
                intersection_component_count: 0
              )
            when :thin_overlap
              return overlap_recheck_result(
                701,
                [cell_id1, cell_id2],
                true,
                'NATIVE_OVERLAP_WITHIN_VALIDATION_TOLERANCE',
                status: 'suppressed',
                actual_overlap_volume: result[:volume],
                intersection_component_count: result[:component_count]
              )
            when :overlap
              store_native_validity_overlap_geometry(
                [cell_id1, cell_id2],
                result
              )
              return overlap_recheck_result(
                701,
                [cell_id1, cell_id2],
                false,
                'NATIVE_POSITIVE_VOLUME_OVERLAP',
                status: 'kept',
                actual_overlap_volume: result[:volume],
                intersection_component_count: result[:component_count]
              )
            end

            fallback_701_cell_pair(cell_id1, cell_id2)
          end

          def fallback_701_cell_pair(cell_id1, cell_id2)
            analysis = full_overlap_rechecker.pair_analysis(cell_id1, cell_id2)
            if analysis[:status] == :inconclusive
              return overlap_recheck_result(
                701,
                [cell_id1, cell_id2],
                false,
                analysis[:reason],
                status: 'inconclusive'
              )
            end

            intersection = Hash(analysis[:intersection])
            if intersection[:status] == :not_reproduced
              return overlap_recheck_result(
                701,
                [cell_id1, cell_id2],
                true,
                intersection[:reason] || 'NO_VALID_INTERSECTION_GROUP_RETURNED',
                status: 'suppressed',
                actual_overlap_volume: 0.0,
                intersection_component_count: 0
              )
            end

            if intersection[:status] == :reproduced
              return overlap_recheck_result(
                701,
                [cell_id1, cell_id2],
                false,
                intersection[:reason] || 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION',
                status: 'kept',
                actual_overlap_volume: intersection[:volume],
                intersection_component_count: intersection[:component_count]
              )
            end

            overlap_recheck_result(
              701,
              [cell_id1, cell_id2],
              false,
              intersection[:reason] || 'BOOLEAN_INTERSECTION_INCONCLUSIVE',
              status: 'inconclusive',
              actual_overlap_volume: intersection[:volume],
              intersection_component_count: intersection[:component_count]
            )
          end

          def recheck_704_cell_pair(cell_id1, cell_id2)
            key = validity_result_key(704, cell_id1, cell_id2)
            result = @validity_native_results && @validity_native_results[key]

            if @validity_native_ran
              return exact_704_result(cell_id1, cell_id2, result)
            end

            compatibility = @validity_core_704_results &&
              @validity_core_704_results[key]
            exact_704_result(cell_id1, cell_id2, compatibility)
          end

          def exact_704_result(cell_id1, cell_id2, result)
            case result && result[:status]
            when :adjacent
              overlap_recheck_result(
                704,
                [cell_id1, cell_id2],
                true,
                'NATIVE_EXACT_FACE_ADJACENCY',
                status: 'suppressed'
              )
            when :not_adjacent
              overlap_recheck_result(
                704,
                [cell_id1, cell_id2],
                false,
                'NATIVE_NO_EXACT_FACE_ADJACENCY',
                status: 'kept'
              )
            else
              overlap_recheck_result(
                704,
                [cell_id1, cell_id2],
                false,
                'NATIVE_EXACT_ADJACENCY_INCONCLUSIVE',
                status: 'inconclusive'
              )
            end
          end

          def validity_result_key(code, cell_id1, cell_id2)
            [code.to_i, *[cell_id1.to_s, cell_id2.to_s].sort]
          end

          def store_native_validity_overlap_geometry(cell_ids, result)
            vertices = Array(result[:vertices])
            triangle_indices = Array(result[:triangles])
            return false if vertices.empty? || triangle_indices.empty?

            indoor_model = @indoor_model || IndoorModel.current
            root = indoor_model&.primal_group
            points = vertices.map do |coordinates|
              local = Geom::Point3d.new(*Array(coordinates).map(&:to_f))
              Utils::Transformation.root_local_point_to_model(local, root)
            end
            triangles = triangle_indices.map do |indices|
              Array(indices).map { |index| points.fetch(index.to_i) }
            end
            ValidationErrorGeometryResolver.store_overlap_geometry(
              model: @model || indoor_model&.model || Sketchup.active_model,
              cell_ids: cell_ids,
              geometry: {
                status: :ready,
                triangles: triangles,
                edges: [],
                volume_in3: result[:volume].to_f
              }
            )
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Native validity overlap overlay cache failed: #{e.class}: #{e.message}"
            )
            false
          end

          def overlap_recheck_result(
            code,
            cell_ids,
            tolerated,
            reason,
            status: nil,
            distance: nil,
            overlap_area: nil,
            normal_thickness: nil,
            actual_overlap_volume: nil,
            intersection_component_count: nil
          )
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

          def full_overlap_rechecker
            indoor_model = @indoor_model || IndoorModel.current
            @full_overlap_rechecker ||= Val3dityFullIntersectionRechecker.new(
              indoor_model: indoor_model,
              model: @model || indoor_model&.model,
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
