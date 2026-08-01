# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/utils/geometry'
require_relative '../indoor3d/application/adjacency_service/geometry_query'
require_relative '../indoor3d/application/adjacency_service/sync'
require_relative '../indoor3d/application/adjacency_service/snapshot_waypoint_reuse'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class SnapshotWaypointContextCleanupTest < Minitest::Test
        def test_nested_context_is_restored
          outer = { outer: true }
          inner = { inner: true }

          AdjacencyService::SnapshotWaypointReuse.with_context(outer) do
            AdjacencyService::SnapshotWaypointReuse.with_context(inner) do
              assert_same inner, AdjacencyService::SnapshotWaypointReuse.current_context
            end
            assert_same outer, AdjacencyService::SnapshotWaypointReuse.current_context
          end

          assert_nil AdjacencyService::SnapshotWaypointReuse.current_context
        end

        def test_exception_does_not_leak_context
          assert_raises(RuntimeError) do
            AdjacencyService::SnapshotWaypointReuse.with_context({ active: true }) do
              raise 'builder failed'
            end
          end

          assert_nil AdjacencyService::SnapshotWaypointReuse.current_context
        end
      end
    end
  end
end
