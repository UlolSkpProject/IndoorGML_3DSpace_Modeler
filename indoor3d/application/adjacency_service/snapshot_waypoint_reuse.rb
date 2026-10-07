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

        module SnapshotWaypointGeometryConversion
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

        GeometryQuery.singleton_class.prepend(SnapshotWaypointGeometryConversion) unless
          GeometryQuery.singleton_class.ancestors.include?(SnapshotWaypointGeometryConversion)
        prepend SnapshotWaypointService unless ancestors.include?(SnapshotWaypointService)
      end
    end
  end
end
