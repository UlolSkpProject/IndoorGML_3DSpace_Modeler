# frozen_string_literal: true

require 'minitest/autorun'

module Geom
  Point3d = Struct.new(:x, :y, :z) do
    def to_a = [x, y, z]

    def distance(other)
      Math.sqrt(((x - other.x)**2) + ((y - other.y)**2) + ((z - other.z)**2))
    end
  end
  Vector3d = Struct.new(:x, :y, :z)
end

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        DEFAULT_TOLERANCE = 0.001
        ADJACENCY_TOLERANCE = 0.001

        def self.dominant_axis(_normal) = :x

        def self.dot_product(first, second)
          (first.x * second.x) + (first.y * second.y) + (first.z * second.z)
        end

        def self.project_points_for_axis(points, _axis)
          points.map { |point| [point.y, point.z] }
        end

        def self.point_in_polygon_2d?(_point, _polygon, _tolerance) = true
      end
    end

    module IndoorCore
      module NativeAdjacencyBridge
        def self.reference_waypoint_anchors(_first, _second, _waypoint)
          [[0.0, 0.0, 4.0], [0.0, 10.0, 20.0]]
        end
      end
    end
  end
end

require_relative '../indoor3d/application/adjacency_service/geometry_query'

class ReferenceWaypointAnchorGeometryTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Query = Core::AdjacencyService::GeometryQuery

  def test_closest_reference_points_replace_state_height_sources
    centroid = Geom::Point3d.new(0.0, 5.0, 12.0)
    anchors = Query.send(
      :reference_waypoint_anchor_points, 'cell-1', 'cell-2', centroid
    )
    assert_equal [4.0, 20.0], anchors.map(&:z)

    face = {
      points: [
        Geom::Point3d.new(0.0, 0.0, 0.0),
        Geom::Point3d.new(0.0, 10.0, 0.0),
        Geom::Point3d.new(0.0, 10.0, 30.0),
        Geom::Point3d.new(0.0, 0.0, 30.0)
      ]
    }
    candidate = {
      centroid: centroid,
      face1: face,
      face2: face,
      normal1: Geom::Vector3d.new(1.0, 0.0, 0.0)
    }
    adjusted = Query.send(
      :adjusted_waypoint, candidate, anchors[0], anchors[1], 0.001
    )

    expected_ratio = anchors[0].distance(centroid) /
                     (anchors[0].distance(centroid) + anchors[1].distance(centroid))
    expected_z = 4.0 + ((20.0 - 4.0) * expected_ratio)
    assert_in_delta expected_z, adjusted.z, 1.0e-9
  end
end
