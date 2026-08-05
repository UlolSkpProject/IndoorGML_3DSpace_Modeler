# frozen_string_literal: true

require 'thread'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AdjacencyService
        module SnapshotWaypointReuse
          THREAD_KEY = :__indoor_gml_snapshot_waypoint_context

          class << self
            def with_context(context, service: nil)
              previous = Thread.current[THREAD_KEY]
              Thread.current[THREAD_KEY] = { context: context, service: service }
              yield
            ensure
              Thread.current[THREAD_KEY] = previous
            end

            def current_context
              payload = Thread.current[THREAD_KEY]
              payload && payload[:context]
            end

            def record_conversion_fallback
              payload = Thread.current[THREAD_KEY]
              service = payload && payload[:service]
              return unless service

              service.send(:record_snapshot_waypoint_conversion_fallback)
            rescue StandardError
              nil
            end
          end
        end

        module SnapshotWaypointGeometryQuery
          def analyze_snapshot_pair(snapshot1, snapshot2, tolerance:)
            faces1 = snapshot1.is_a?(Hash) ? snapshot1[:faces] : nil
            faces2 = snapshot2.is_a?(Hash) ? snapshot2[:faces] : nil
            return unsupported_snapshot_analysis unless faces1.is_a?(Array) && faces2.is_a?(Array)
            return unsupported_snapshot_analysis if faces1.empty? || faces2.empty?

            tolerance_value = tolerance.to_f
            area_tolerance = tolerance_value * tolerance_value
            axis = nil
            adjacent = false
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

                adjacent = true
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
                }.freeze
              end
            end

            {
              supported: true,
              adjacent: adjacent,
              axis: axis,
              waypoint_snapshot_candidates: waypoint_candidates.freeze
            }.freeze
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Snapshot waypoint pair analysis failed: #{e.class}: #{e.message}"
            ) if defined?(IndoorCore::Logger)
            unsupported_snapshot_analysis
          end

          def waypoint_candidates_from_snapshot_context(
            context,
            state1_point:,
            state2_point:,
            tolerance:
          )
            raw = Array(context && context[:waypoint_snapshot_candidates])
            return [] if raw.empty?

            max_area = raw.map { |candidate| candidate[:area].to_f }.max
            selected = raw.select do |candidate|
              (candidate[:area].to_f - max_area).abs <= tolerance.to_f
            end

            selected.filter_map do |candidate|
              geometry_candidate = geometry_candidate_from_snapshot(candidate)
              next nil unless geometry_candidate

              point = adjusted_waypoint(
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
            IndoorCore::Logger.puts(
              "[IndoorGML] Snapshot waypoint conversion failed: #{e.class}: #{e.message}"
            ) if defined?(IndoorCore::Logger)
            []
          end

          private

          def unsupported_snapshot_analysis
            {
              supported: false,
              adjacent: false,
              axis: nil,
              waypoint_snapshot_candidates: [].freeze
            }.freeze
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
                overlap = Utils::Geometry.send(:clip_polygon, polygon1, polygon2)
                area = Utils::Geometry.send(:polygon_area_2d, overlap).abs
                adjacent_area += area
                next if overlap.length < 3 || area <= area_tolerance

                centroid = Utils::Geometry.send(:polygon_centroid_2d, overlap)
                weighted_x += centroid[0] * area
                weighted_y += centroid[1] * area
                waypoint_area += area
              end
            end

            waypoint_metrics = if waypoint_area > area_tolerance
                                 {
                                   area: waypoint_area,
                                   centroid_2d: [
                                     weighted_x / waypoint_area,
                                     weighted_y / waypoint_area
                                   ]
                                 }
                               end
            {
              adjacent: adjacent_area > area_tolerance,
              waypoint_metrics: waypoint_metrics
            }
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
              vector = [
                point[0] - plane_point[0],
                point[1] - plane_point[1],
                point[2] - plane_point[2]
              ]
              snapshot_dot(vector, normal).abs <= tolerance
            end
          end

          def snapshot_dot(vector1, vector2)
            (vector1[0] * vector2[0]) +
              (vector1[1] * vector2[1]) +
              (vector1[2] * vector2[2])
          end

          def geometry_candidate_from_snapshot(candidate)
            face1 = geometry_face(candidate[:face1])
            face2 = geometry_face(candidate[:face2])
            return nil unless face1 && face2

            normal1 = face1[:normal]
            normal2 = face2[:normal]
            plane_point = face1[:points].first
            centroid = unproject_point(
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
        end

        module SnapshotWaypointService
          def synchronize_all(transition_builder: nil, transition_eraser: nil, progress: nil)
            reset_snapshot_waypoint_metrics
            metrics = super
            append_snapshot_waypoint_metrics(metrics)
          ensure
            clear_snapshot_waypoint_contexts
          end

          def synchronize_within(cell_spaces, transition_builder: nil, transition_eraser: nil, progress: nil)
            reset_snapshot_waypoint_metrics
            metrics = super
            append_snapshot_waypoint_metrics(metrics)
          ensure
            clear_snapshot_waypoint_contexts
          end

          private

          def compute_pair_results(entries, tolerance:, progress: nil)
            prepare_snapshot_waypoint_contexts(entries)
            super
          end

          def compute_pair_chunk(snapshots, pair_indices, tolerance, progress: nil)
            total = pair_indices.length
            emit_stage_start(
              progress,
              stage: :detailed_computation,
              name: 'Adjacency 상세 판정',
              total: total,
              message: "Adjacency 상세 판정: 0 / #{total}"
            )

            results = []
            pair_indices.each_with_index do |(index1, index2), index|
              started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              analysis = AdjacencyService::GeometryQuery.analyze_snapshot_pair(
                snapshots[index1],
                snapshots[index2],
                tolerance: tolerance
              )
              record_snapshot_waypoint_pair_analysis(
                Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
              )

              if analysis[:supported]
                if analysis[:adjacent]
                  store_snapshot_waypoint_context(index1, index2, analysis)
                  results << [index1, index2, analysis[:axis]] unless analysis[:axis].nil?
                end
              else
                axis = Utils::Geometry.adjacency_axis_from_snapshots(
                  snapshots[index1],
                  snapshots[index2],
                  tolerance: tolerance
                )
                results << [index1, index2, axis] unless axis.nil?
              end

              completed = index + 1
              emit_stage_progress(
                progress,
                stage: :detailed_computation,
                name: 'Adjacency 상세 판정',
                total: total,
                completed: completed,
                message: "Adjacency 상세 판정: #{completed} / #{total}"
              ) if progress_checkpoint?(completed, total)
            end

            emit_stage_finish(
              progress,
              stage: :detailed_computation,
              name: 'Adjacency 상세 판정',
              total: total,
              completed: total,
              message: "Adjacency 상세 판정 완료: #{results.length}개 인접",
              telemetry: {
                candidate_pair_count: total,
                adjacent_pair_count: results.length
              }
            )
            results
          end

          def apply_pair_results(
            entries,
            pair_results,
            transition_builder:,
            transition_eraser:,
            stale_pair_keys: nil,
            progress: nil
          )
            wrapped_builder = proc do |cell1, cell2|
              context = snapshot_waypoint_context_for(cell1, cell2)
              if context
                @snapshot_waypoint_context_hits = @snapshot_waypoint_context_hits.to_i + 1
              else
                @snapshot_waypoint_context_fallbacks = @snapshot_waypoint_context_fallbacks.to_i + 1
              end
              SnapshotWaypointReuse.with_context(context, service: self) do
                transition_builder.call(cell1, cell2)
              end
            end

            super(
              entries,
              pair_results,
              transition_builder: wrapped_builder,
              transition_eraser: transition_eraser,
              stale_pair_keys: stale_pair_keys,
              progress: progress
            )
          ensure
            clear_snapshot_waypoint_contexts
          end

          def prepare_snapshot_waypoint_contexts(entries)
            @snapshot_waypoint_entries = Array(entries)
            @snapshot_waypoint_contexts = {}
            @snapshot_waypoint_mutex ||= Mutex.new
          end

          def store_snapshot_waypoint_context(index1, index2, context)
            entry1 = @snapshot_waypoint_entries[index1]
            entry2 = @snapshot_waypoint_entries[index2]
            return unless entry1 && entry2

            pair_key = cell_pair_key(entry1[:cell_space], entry2[:cell_space])
            @snapshot_waypoint_mutex.synchronize do
              @snapshot_waypoint_contexts[pair_key] = context
            end
          rescue StandardError
            nil
          end

          def snapshot_waypoint_context_for(cell1, cell2)
            pair_key = cell_pair_key(cell1, cell2)
            @snapshot_waypoint_mutex.synchronize do
              Hash(@snapshot_waypoint_contexts)[pair_key]
            end
          rescue StandardError
            nil
          end

          def reset_snapshot_waypoint_metrics
            @snapshot_waypoint_pair_analysis_count = 0
            @snapshot_waypoint_pair_analysis_duration = 0.0
            @snapshot_waypoint_context_hits = 0
            @snapshot_waypoint_context_fallbacks = 0
            @snapshot_waypoint_metrics_mutex ||= Mutex.new
          end

          def record_snapshot_waypoint_pair_analysis(elapsed)
            @snapshot_waypoint_metrics_mutex ||= Mutex.new
            @snapshot_waypoint_metrics_mutex.synchronize do
              @snapshot_waypoint_pair_analysis_count =
                @snapshot_waypoint_pair_analysis_count.to_i + 1
              @snapshot_waypoint_pair_analysis_duration =
                @snapshot_waypoint_pair_analysis_duration.to_f + elapsed.to_f
            end
          end

          def record_snapshot_waypoint_conversion_fallback
            @snapshot_waypoint_context_fallbacks =
              @snapshot_waypoint_context_fallbacks.to_i + 1
          end

          def append_snapshot_waypoint_metrics(metrics)
            return metrics unless metrics.is_a?(Hash)

            metrics[:waypoint_snapshot_pair_analysis_count] =
              @snapshot_waypoint_pair_analysis_count.to_i
            metrics[:waypoint_snapshot_pair_analysis_duration] =
              @snapshot_waypoint_pair_analysis_duration.to_f
            metrics[:waypoint_snapshot_context_hits] =
              @snapshot_waypoint_context_hits.to_i
            metrics[:waypoint_snapshot_context_fallbacks] =
              @snapshot_waypoint_context_fallbacks.to_i
            metrics
          end

          def clear_snapshot_waypoint_contexts
            @snapshot_waypoint_entries = nil
            @snapshot_waypoint_contexts = nil
          end
        end

        GeometryQuery.singleton_class.prepend(SnapshotWaypointGeometryQuery) unless
          GeometryQuery.singleton_class.ancestors.include?(SnapshotWaypointGeometryQuery)
        prepend SnapshotWaypointService unless ancestors.include?(SnapshotWaypointService)
      end
    end
  end
end
