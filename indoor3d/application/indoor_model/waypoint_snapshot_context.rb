# frozen_string_literal: true

require_relative '../adjacency_service/snapshot_waypoint_reuse'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module WaypointSnapshotContext
          private

          def transition_waypoint_candidates(transition)
            context = AdjacencyService::SnapshotWaypointReuse.current_context
            return super unless context && context.key?(:waypoint_snapshot_candidates)

            raw_candidates = Array(context[:waypoint_snapshot_candidates])
            candidates = AdjacencyService::GeometryQuery.waypoint_candidates_from_snapshot_context(
              context,
              state1_point: state_root_local_position(transition.state1),
              state2_point: state_root_local_position(transition.state2),
              tolerance: Utils::Geometry::ADJACENCY_TOLERANCE
            )

            if candidates.empty? && !raw_candidates.empty?
              AdjacencyService::SnapshotWaypointReuse.record_conversion_fallback
              return super
            end

            candidates.filter_map do |candidate|
              normalize_root_local_waypoint_candidate(candidate, transition)
            end
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Snapshot transition waypoint failed: #{e.class}: #{e.message}"
            ) if defined?(IndoorCore::Logger)
            AdjacencyService::SnapshotWaypointReuse.record_conversion_fallback
            super
          end
        end

        prepend WaypointSnapshotContext unless ancestors.include?(WaypointSnapshotContext)
      end
    end
  end
end
