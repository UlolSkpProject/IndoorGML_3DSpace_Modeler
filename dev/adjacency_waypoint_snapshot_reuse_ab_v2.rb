# frozen_string_literal: true

# Patch loader for adjacency_waypoint_snapshot_reuse_ab.rb.
# SketchUp geometry helpers such as clip_polygon are private singleton methods,
# so the experiment must invoke them via `send` instead of a public call.

base_script = File.join(__dir__, 'adjacency_waypoint_snapshot_reuse_ab.rb')
load(base_script) unless defined?(
  ULOL::Indoor3DGmlModeler::IndoorCore::AdjacencyWaypointSnapshotReuseAB
)

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module AdjacencyWaypointSnapshotReuseAB
        class << self
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

            metrics = if waypoint_area > area_tolerance
                        {
                          area: waypoint_area,
                          centroid_2d: [weighted_x / waypoint_area, weighted_y / waypoint_area]
                        }
                      end
            { adjacent: adjacent_area > area_tolerance, waypoint_metrics: metrics }
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::AdjacencyWaypointSnapshotReuseAB.reset!
puts '[ADJACENCY WAYPOINT SNAPSHOT A/B V2] private geometry helper calls fixed'
puts 'A: ...::AdjacencyWaypointSnapshotReuseAB.baseline!'
puts 'B: reopen source SKP, then ...::AdjacencyWaypointSnapshotReuseAB.optimized!'
