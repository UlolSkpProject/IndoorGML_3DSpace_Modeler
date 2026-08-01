# frozen_string_literal: true

# Dev-only A/B experiment for reusing adjacency snapshot overlap results when
# building Transition waypoint candidates.
#
# A: baseline!  -> normal live-face waypoint query
# B: optimized! -> reuse snapshot overlap candidates; fail-open to baseline
#
# Reopen the same unconverted SKP between A and B without restarting SketchUp.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      unless const_defined?(:AdjacencyWaypointSnapshotReuseAB, false)
        module AdjacencyWaypointSnapshotReuseAB
          CLOCK = Process::CLOCK_MONOTONIC
          MODES = [:baseline, :optimized].freeze
          ROUND_DIGITS = 8
          LOG_PATH = File.join(
            ENV['TEMP'] || ENV['TMP'] || '.',
            'IndoorGML_Adjacency_Waypoint_Snapshot_Reuse_AB.log'
          ).freeze
          CONTEXT_KEY = :__indoor_gml_waypoint_snapshot_context

          class << self
            def install!
              AdjacencyService.prepend(ServiceProbe) unless AdjacencyService.ancestors.include?(ServiceProbe)
              IndoorModel.prepend(IndoorModelProbe) unless IndoorModel.ancestors.include?(IndoorModelProbe)

              singleton = AdjacencyService::GeometryQuery.singleton_class
              singleton.prepend(GeometryQueryProbe) unless singleton.ancestors.include?(GeometryQueryProbe)

              @reports ||= {}
              puts '[ADJACENCY WAYPOINT SNAPSHOT A/B] installed'
              puts 'A: ...::AdjacencyWaypointSnapshotReuseAB.baseline!'
              puts 'B: reopen source SKP, then ...::AdjacencyWaypointSnapshotReuseAB.optimized!'
              puts "Log: #{LOG_PATH}"
              true
            rescue StandardError => e
              warn_error('install', e)
              false
            end

            def baseline!
              arm!(:baseline)
            end

            def optimized!
              arm!(:optimized)
            end

            def arm!(mode)
              mode = mode.to_sym
              raise ArgumentError, "Unknown mode: #{mode.inspect}" unless MODES.include?(mode)

              @armed_mode = mode
              puts "[ADJACENCY WAYPOINT SNAPSHOT A/B] armed #{mode_label(mode)} for next synchronize_all"
              true
            end

            def reset!
              @armed_mode = nil
              @active_mode = nil
              @reports = {}
              @comparison_lines = nil
              clear_run_state!
              File.delete(LOG_PATH) if File.file?(LOG_PATH)
              puts '[ADJACENCY WAYPOINT SNAPSHOT A/B] reset'
              true
            rescue StandardError
              true
            end

            def consume_armed_mode!
              mode = @armed_mode
              @armed_mode = nil
              mode
            end

            def active?
              !@active_mode.nil?
            end

            def optimized_active?
              @active_mode == :optimized
            end

            def begin_run!(service, mode)
              @active_mode = mode
              @active_service_id = service.object_id
              @run_started_at = now
              @stats = Hash.new { |hash, key| hash[key] = { calls: 0, total: 0.0 } }
              @entries = nil
              @contexts = {}
              @context_mutex ||= Mutex.new
              Thread.current[CONTEXT_KEY] = nil
              true
            end

            def finish_run!(service, result, error = nil)
              elapsed = @run_started_at ? now - @run_started_at : 0.0
              report = build_report(service, result, elapsed, error)
              @reports ||= {}
              @reports[@active_mode] = report if @active_mode
              print_report(report)
              compare! if @reports[:baseline] && @reports[:optimized]
              write_log
              report
            rescue StandardError => e
              warn_error('finish', e)
              nil
            ensure
              @active_mode = nil
              @active_service_id = nil
              @run_started_at = nil
              Thread.current[CONTEXT_KEY] = nil
              clear_run_state!
            end

            def register_entries(entries)
              @entries = Array(entries)
              @contexts = {}
            end

            def store_pair_context(index1, index2, context)
              return unless optimized_active?
              return unless context

              pair_key = pair_key_for_indices(index1, index2)
              return if pair_key.nil?

              @context_mutex.synchronize { @contexts[pair_key] = context }
            end

            def context_for_cells(cell1, cell2)
              key = [safe_id(cell1), safe_id(cell2)].sort.join(':')
              @context_mutex.synchronize { @contexts[key] }
            rescue StandardError
              nil
            end

            def with_transition_context(context)
              previous = Thread.current[CONTEXT_KEY]
              Thread.current[CONTEXT_KEY] = context
              yield
            ensure
              Thread.current[CONTEXT_KEY] = previous
            end

            def current_transition_context
              Thread.current[CONTEXT_KEY]
            end

            def measure(name)
              return yield unless active?

              started = now
              result = yield
              result
            ensure
              record(name, now - started) if started
            end

            def record(name, elapsed)
              stat = @stats[name]
              stat[:calls] += 1
              stat[:total] += elapsed.to_f
            rescue StandardError
              nil
            end

            def analyze_snapshot_pair(snapshot1, snapshot2, tolerance)
              return nil unless snapshot1 && snapshot2

              faces1 = Array(snapshot1[:faces])
              faces2 = Array(snapshot2[:faces])
              return nil if faces1.empty? || faces2.empty?

              tolerance_value = tolerance.to_f
              area_tolerance = tolerance_value * tolerance_value
              axis = nil
              waypoint_candidates = []

              faces1.each do |face1|
                faces2.each do |face2|
                  next unless snapshot_normals_opposite?(face1[:normal], face2[:normal])
                  next unless snapshot_points_on_plane?(
                    face2[:points],
                    face1[:normal],
                    face1[:points].first,
                    tolerance_value
                  )

                  overlap = snapshot_overlap_analysis(face1, face2, area_tolerance)
                  next unless overlap[:adjacent]

                  face_axis = dominant_snapshot_axis(face1[:normal])
                  axis ||= face_axis
                  metrics = overlap[:waypoint_metrics]
                  next unless metrics

                  waypoint_candidates << {
                    area: metrics[:area],
                    centroid_2d: metrics[:centroid_2d],
                    axis: face_axis,
                    face1: face1,
                    face2: face2
                  }
                end
              end

              return nil if axis.nil?

              {
                axis: axis,
                waypoint_snapshot_candidates: waypoint_candidates.freeze
              }.freeze
            end

            def waypoint_candidates_from_context(context, state1_point:, state2_point:, tolerance:)
              raw = Array(context && context[:waypoint_snapshot_candidates])
              return [] if raw.empty?

              max_area = raw.map { |candidate| candidate[:area].to_f }.max
              selected = raw.select do |candidate|
                (candidate[:area].to_f - max_area).abs <= tolerance.to_f
              end

              selected.filter_map do |candidate|
                geometry_candidate = geometry_candidate_from_snapshot(candidate)
                next nil unless geometry_candidate

                point = AdjacencyService::GeometryQuery.send(
                  :adjusted_waypoint,
                  geometry_candidate,
                  state1_point,
                  state2_point,
                  tolerance
                )
                next nil unless point.is_a?(Geom::Point3d)

                {
                  point: point,
                  normal1: geometry_candidate[:normal1],
                  normal2: geometry_candidate[:normal2]
                }
              end
            rescue StandardError => e
              warn_error('snapshot waypoint conversion', e)
              []
            end

            def compare!
              baseline = @reports[:baseline]
              optimized = @reports[:optimized]
              same_transitions = baseline[:transition_count] == optimized[:transition_count]
              same_signatures = baseline[:transition_signatures] == optimized[:transition_signatures]
              elapsed_delta = optimized[:elapsed] - baseline[:elapsed]
              service_delta = optimized[:service_total] - baseline[:service_total]
              detailed_delta = optimized[:service_detailed] - baseline[:service_detailed]

              lines = []
              lines << '=' * 118
              lines << 'Adjacency Waypoint Snapshot Reuse A/B Comparison'
              lines << '=' * 118
              lines << "Transition count          : #{same_transitions ? 'PASS' : 'FAIL'}  #{baseline[:transition_count]} / #{optimized[:transition_count]}"
              lines << "Transition geometry       : #{same_signatures ? 'PASS' : 'FAIL'}"
              lines << "Baseline errors           : #{baseline[:error] ? 'FAIL' : 'PASS'}"
              lines << "Optimized errors          : #{optimized[:error] ? 'FAIL' : 'PASS'}"
              lines << '-' * 118
              lines << metric_line('synchronize_all elapsed', baseline[:elapsed], optimized[:elapsed], elapsed_delta)
              lines << metric_line('Service reported total', baseline[:service_total], optimized[:service_total], service_delta)
              lines << metric_line('Detailed geometry', baseline[:service_detailed], optimized[:service_detailed], detailed_delta)
              lines << metric_line('Live waypoint query', baseline[:live_query_total], optimized[:live_query_total], optimized[:live_query_total] - baseline[:live_query_total])
              lines << metric_line('Snapshot pair analysis', baseline[:snapshot_analysis_total], optimized[:snapshot_analysis_total], optimized[:snapshot_analysis_total] - baseline[:snapshot_analysis_total])
              lines << '-' * 118
              verdict = if !same_transitions || !same_signatures || baseline[:error] || optimized[:error]
                          'REJECT — FUNCTIONAL DIFFERENCE'
                        elsif optimized[:elapsed] < baseline[:elapsed]
                          'PASS — OPTIMIZED FASTER'
                        else
                          'PASS FUNCTIONALLY — NO SPEEDUP'
                        end
              lines << "VERDICT                   : #{verdict}"
              lines << '=' * 118
              @comparison_lines = lines
              puts
              lines.each { |line| puts line }
              true
            end

            def build_report(service, result, elapsed, error)
              metrics = result.is_a?(Hash) ? result : (service.respond_to?(:last_metrics) ? service.last_metrics : {})
              model = IndoorModel.current
              signatures = transition_signatures(model.transitions)
              {
                mode: @active_mode,
                elapsed: elapsed.to_f,
                service_total: metrics[:total_duration].to_f,
                service_detailed: metrics[:adjacency_detailed_computation].to_f,
                pair_count: metrics[:pair_comparison_count].to_i,
                transition_count: Array(model.transitions).count { |transition| transition&.valid? },
                transition_signatures: signatures,
                live_query_calls: stat_calls('live waypoint query'),
                live_query_total: stat_total('live waypoint query'),
                snapshot_analysis_calls: stat_calls('snapshot pair analysis'),
                snapshot_analysis_total: stat_total('snapshot pair analysis'),
                snapshot_context_hits: stat_calls('snapshot context hit'),
                snapshot_context_fallbacks: stat_calls('snapshot context fallback'),
                error: error && "#{error.class}: #{error.message}"
              }
            end

            def print_report(report)
              lines = []
              lines << '=' * 118
              lines << "Adjacency Waypoint Snapshot Reuse — #{mode_label(report[:mode])}"
              lines << '=' * 118
              lines << "Candidate pairs            : #{report[:pair_count]}"
              lines << "Transitions                : #{report[:transition_count]}"
              lines << format('synchronize_all elapsed   : %10.3f sec', report[:elapsed])
              lines << format('Service reported total    : %10.3f sec', report[:service_total])
              lines << format('Service detailed geometry : %10.3f sec', report[:service_detailed])
              lines << '-' * 118
              lines << format('Live waypoint query       : %6d calls %10.3f sec', report[:live_query_calls], report[:live_query_total])
              lines << format('Snapshot pair analysis    : %6d calls %10.3f sec', report[:snapshot_analysis_calls], report[:snapshot_analysis_total])
              lines << "Snapshot context hits     : #{report[:snapshot_context_hits]}"
              lines << "Snapshot fallbacks        : #{report[:snapshot_context_fallbacks]}"
              lines << "Error                     : #{report[:error] || 'none'}"
              lines << '=' * 118
              report[:lines] = lines
              puts
              lines.each { |line| puts line }
            end

            def write_log
              lines = []
              [:baseline, :optimized].each do |mode|
                report = @reports && @reports[mode]
                next unless report

                lines.concat(report[:lines] || [])
                lines << ''
              end
              lines.concat(@comparison_lines || [])
              File.write(LOG_PATH, lines.join("\n") + "\n")
              puts "Log: #{LOG_PATH}"
            rescue StandardError => e
              warn_error('log', e)
            end

            def transition_signatures(transitions)
              Array(transitions).filter_map do |transition|
                next unless transition&.valid?

                endpoints = [point_signature(transition.state1_point), point_signature(transition.state2_point)].sort
                candidates = Array(transition.waypoint_candidates).filter_map do |candidate|
                  next unless candidate.is_a?(Hash)

                  [
                    point_signature(candidate[:point]),
                    vector_signature(candidate[:normal1]),
                    vector_signature(candidate[:normal2])
                  ]
                end.sort_by(&:inspect)
                selected = point_signature(transition.selected_waypoint)
                [endpoints, candidates, selected]
              end.sort_by(&:inspect)
            end

            def point_signature(point)
              return nil unless point.is_a?(Geom::Point3d)

              [point.x.to_f.round(ROUND_DIGITS), point.y.to_f.round(ROUND_DIGITS), point.z.to_f.round(ROUND_DIGITS)]
            end

            def vector_signature(vector)
              return nil unless vector.is_a?(Geom::Vector3d)

              [vector.x.to_f.round(ROUND_DIGITS), vector.y.to_f.round(ROUND_DIGITS), vector.z.to_f.round(ROUND_DIGITS)]
            end

            def metric_line(name, baseline, optimized, delta)
              percent = baseline.to_f.zero? ? 0.0 : delta.to_f / baseline.to_f * 100.0
              format('%-28s %10.3f s -> %10.3f s  delta=%+10.3f s (%+7.1f%%)', name, baseline, optimized, delta, percent)
            end

            def stat_calls(name)
              (@stats && @stats[name] && @stats[name][:calls]).to_i
            end

            def stat_total(name)
              (@stats && @stats[name] && @stats[name][:total]).to_f
            end

            def pair_key_for_indices(index1, index2)
              entry1 = Array(@entries)[index1]
              entry2 = Array(@entries)[index2]
              return nil unless entry1 && entry2

              [safe_id(entry1[:cell_space]), safe_id(entry2[:cell_space])].sort.join(':')
            end

            def safe_id(cell)
              cell.respond_to?(:id) ? cell.id.to_s : cell.object_id.to_s
            rescue StandardError
              cell.object_id.to_s
            end

            def geometry_candidate_from_snapshot(candidate)
              face1 = geometry_face(candidate[:face1])
              face2 = geometry_face(candidate[:face2])
              return nil unless face1 && face2

              normal1 = face1[:normal]
              normal2 = face2[:normal]
              plane_point = face1[:points].first
              centroid = AdjacencyService::GeometryQuery.send(
                :unproject_point,
                candidate[:centroid_2d],
                candidate[:axis],
                normal1,
                plane_point
              )
              return nil unless centroid

              {
                area: candidate[:area].to_f,
                centroid: centroid,
                normal1: normal1,
                normal2: normal2,
                face1: face1,
                face2: face2
              }
            end

            def geometry_face(snapshot_face)
              return nil unless snapshot_face

              points = Array(snapshot_face[:points]).map do |point|
                Geom::Point3d.new(point[0], point[1], point[2])
              end
              normal = Array(snapshot_face[:normal])
              return nil if points.length < 3 || normal.length < 3

              vector = Geom::Vector3d.new(normal[0], normal[1], normal[2])
              vector.normalize! if vector.length > 0.001
              { points: points, normal: vector }
            rescue StandardError
              nil
            end

            def snapshot_overlap_analysis(face1, face2, area_tolerance)
              axis = dominant_snapshot_axis(face1[:normal])
              adjacent_area = 0.0
              weighted_x = 0.0
              weighted_y = 0.0
              waypoint_area = 0.0

              Array(face1[:triangles]).each do |triangle1|
                polygon1 = project_snapshot_points(triangle1, axis)
                Array(face2[:triangles]).each do |triangle2|
                  polygon2 = project_snapshot_points(triangle2, axis)
                  overlap = Utils::Geometry.clip_polygon(polygon1, polygon2)
                  area = Utils::Geometry.polygon_area_2d(overlap).abs
                  adjacent_area += area
                  next if overlap.length < 3 || area <= area_tolerance

                  centroid = Utils::Geometry.polygon_centroid_2d(overlap)
                  weighted_x += centroid[0] * area
                  weighted_y += centroid[1] * area
                  waypoint_area += area
                end
              end

              metrics = if waypoint_area > area_tolerance
                          {
                            area: waypoint_area,
                            centroid_2d: [weighted_x / waypoint_area, weighted_y / waypoint_area]
                          }
                        end
              { adjacent: adjacent_area > area_tolerance, waypoint_metrics: metrics }
            end

            def project_snapshot_points(points, axis)
              Array(points).map do |point|
                case axis
                when :x then [point[1].to_f, point[2].to_f]
                when :y then [point[0].to_f, point[2].to_f]
                else [point[0].to_f, point[1].to_f]
                end
              end
            end

            def dominant_snapshot_axis(vector)
              values = { x: vector[0].abs, y: vector[1].abs, z: vector[2].abs }
              values.max_by { |_axis, value| value }.first
            end

            def snapshot_normals_opposite?(normal1, normal2)
              (snapshot_dot(normal1, normal2) + 1.0).abs <= 0.000001
            end

            def snapshot_points_on_plane?(points, normal, plane_point, tolerance)
              Array(points).all? do |point|
                vector = [point[0] - plane_point[0], point[1] - plane_point[1], point[2] - plane_point[2]]
                snapshot_dot(vector, normal).abs <= tolerance
              end
            end

            def snapshot_dot(vector1, vector2)
              (vector1[0] * vector2[0]) + (vector1[1] * vector2[1]) + (vector1[2] * vector2[2])
            end

            def now
              Process.clock_gettime(CLOCK)
            end

            def clear_run_state!
              @entries = nil
              @contexts = {}
              @stats = nil
            end

            def mode_label(mode)
              mode == :optimized ? 'B: SNAPSHOT REUSE' : 'A: BASELINE LIVE QUERY'
            end

            def warn_error(stage, error)
              puts "[ADJACENCY WAYPOINT SNAPSHOT A/B] #{stage} failed: #{error.class}: #{error.message}"
              puts Array(error.backtrace).first(12).join("\n")
            end
          end

          module ServiceProbe
            def synchronize_all(transition_builder: nil, transition_eraser: nil)
              mode = AdjacencyWaypointSnapshotReuseAB.consume_armed_mode!
              return super unless mode

              AdjacencyWaypointSnapshotReuseAB.begin_run!(self, mode)
              error = nil
              result = nil
              begin
                if mode == :optimized
                  original_builder = transition_builder || instance_variable_get(:@transition_builder)
                  wrapped_builder = proc do |cell1, cell2|
                    context = AdjacencyWaypointSnapshotReuseAB.context_for_cells(cell1, cell2)
                    AdjacencyWaypointSnapshotReuseAB.with_transition_context(context) do
                      original_builder.call(cell1, cell2)
                    end
                  end
                  result = super(transition_builder: wrapped_builder, transition_eraser: transition_eraser)
                else
                  result = super(transition_builder: transition_builder, transition_eraser: transition_eraser)
                end
                result
              rescue StandardError => e
                error = e
                raise
              ensure
                AdjacencyWaypointSnapshotReuseAB.finish_run!(self, result, error)
              end
            end

            private

            def compute_pair_results(entries, tolerance:)
              if AdjacencyWaypointSnapshotReuseAB.optimized_active?
                AdjacencyWaypointSnapshotReuseAB.register_entries(entries)
              end
              super
            end

            def compute_pair_chunk(snapshots, pair_indices, tolerance)
              return super unless AdjacencyWaypointSnapshotReuseAB.optimized_active?

              pair_indices.each_with_object([]) do |(index1, index2), results|
                analysis = AdjacencyWaypointSnapshotReuseAB.measure('snapshot pair analysis') do
                  AdjacencyWaypointSnapshotReuseAB.analyze_snapshot_pair(
                    snapshots[index1],
                    snapshots[index2],
                    tolerance
                  )
                end
                next unless analysis

                AdjacencyWaypointSnapshotReuseAB.store_pair_context(index1, index2, analysis)
                results << [index1, index2, analysis[:axis]]
              end
            end
          end

          module IndoorModelProbe
            private

            def transition_waypoint_candidates(transition)
              return super unless AdjacencyWaypointSnapshotReuseAB.optimized_active?

              context = AdjacencyWaypointSnapshotReuseAB.current_transition_context
              unless context && context.key?(:waypoint_snapshot_candidates)
                AdjacencyWaypointSnapshotReuseAB.record('snapshot context fallback', 0.0)
                return super
              end

              state1_point = state_root_local_position(transition.state1)
              state2_point = state_root_local_position(transition.state2)
              candidates = AdjacencyWaypointSnapshotReuseAB.waypoint_candidates_from_context(
                context,
                state1_point: state1_point,
                state2_point: state2_point,
                tolerance: Utils::Geometry::ADJACENCY_TOLERANCE
              )
              if candidates.empty? && !Array(context[:waypoint_snapshot_candidates]).empty?
                AdjacencyWaypointSnapshotReuseAB.record('snapshot context fallback', 0.0)
                return super
              end

              AdjacencyWaypointSnapshotReuseAB.record('snapshot context hit', 0.0)
              candidates.filter_map do |candidate|
                normalize_root_local_waypoint_candidate(candidate, transition)
              end
            rescue StandardError => e
              AdjacencyWaypointSnapshotReuseAB.warn_error('optimized transition waypoint', e)
              AdjacencyWaypointSnapshotReuseAB.record('snapshot context fallback', 0.0)
              super
            end
          end

          module GeometryQueryProbe
            def common_face_waypoint_candidates(*args, **kwargs)
              return super unless AdjacencyWaypointSnapshotReuseAB.active?

              AdjacencyWaypointSnapshotReuseAB.measure('live waypoint query') do
                super
              end
            end
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::AdjacencyWaypointSnapshotReuseAB.install!
