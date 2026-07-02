# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rbconfig'
require 'rexml/document'

require_relative 'val3dity_process_adapter'
require_relative 'val3dity_report_schema'
require_relative 'val3dity_report_renderer'
require_relative 'val3dity_overlap_recheck_policy'
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

            Val3dityRunOrchestration.new(
              session: session,
              progress: progress,
              progress_step: progress_step,
              callback: callback,
              register_session: ->(active_session) { self.class.register_session(active_session) },
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

          def error_code_number(code)
            Val3dityReportSchema.error_code_number(code)
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
            Val3dityReportSchema.error_kind_rows(raw_report)
          end

          def error_item_rows(raw_report)
            Val3dityReportSchema.error_item_rows(raw_report)
          end

          def error_row(scope, item, error)
            Val3dityReportSchema.error_row(scope, item, error)
          end

          def report_error_row_refs(row)
            Val3dityReportSchema.report_error_row_refs(row)
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
