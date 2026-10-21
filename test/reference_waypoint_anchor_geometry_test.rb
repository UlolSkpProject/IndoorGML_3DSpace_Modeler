# frozen_string_literal: true

require 'minitest/autorun'

module Geom
  Point3d = Struct.new(:x, :y, :z) do
    def to_a = [x, y, z]

    def distance(other)
      Math.sqrt(((x - other.x)**2) + ((y - other.y)**2) + ((z - other.z)**2))
    end
  end
  Vector3d = Struct.new(:x, :y, :z) do
    def length = Math.sqrt((x**2) + (y**2) + (z**2))

    def normalize!
      magnitude = length
      return self if magnitude.zero?

      self.x /= magnitude
      self.y /= magnitude
      self.z /= magnitude
      self
    end
  end
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

      end
    end

    module IndoorCore
      module NativeAdjacencyBridge
        def self.reference_waypoint_anchors(_first, _second, _waypoint, **_transforms)
          [[0.0, 0.0, 4.0], [0.0, 10.0, 20.0]]
        end
      end
    end
  end
end

require_relative '../indoor3d/utils/geometry/polygon2d'
require_relative '../indoor3d/application/adjacency_service/geometry_query'
require_relative '../indoor3d/application/adjacency_service/snapshot_waypoint_reuse'

class ReferenceWaypointAnchorGeometryTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Query = Core::AdjacencyService::GeometryQuery

  def wall_face(inner_loops: [])
    {
      points: [
        Geom::Point3d.new(0.0, 0.0, 0.0),
        Geom::Point3d.new(0.0, 10.0, 0.0),
        Geom::Point3d.new(0.0, 10.0, 30.0),
        Geom::Point3d.new(0.0, 0.0, 30.0)
      ],
      inner_loops: inner_loops
    }
  end

  def doorway_hole
    [
      Geom::Point3d.new(0.0, 3.0, 10.0),
      Geom::Point3d.new(0.0, 7.0, 10.0),
      Geom::Point3d.new(0.0, 7.0, 20.0),
      Geom::Point3d.new(0.0, 3.0, 20.0)
    ]
  end

  def test_waypoint_checks_exclude_inner_loop_and_its_boundary
    face = wall_face(inner_loops: [doorway_hole])
    assert Query.send(:point_in_face?, Geom::Point3d.new(0.0, 2.0, 15.0), face, :x, 0.001)
    refute Query.send(:point_in_face?, Geom::Point3d.new(0.0, 5.0, 15.0), face, :x, 0.001)
    refute Query.send(:point_in_face?, Geom::Point3d.new(0.0, 3.0, 15.0), face, :x, 0.001)
    refute Query.send(:point_in_face?, Geom::Point3d.new(0.0, 15.0, 15.0), face, :x, 0.001)
  end

  def test_inner_loop_is_preserved_when_snapshot_face_is_restored
    face = wall_face(inner_loops: [doorway_hole])
    raw = {
      points: face[:points].map(&:to_a),
      normal: [1.0, 0.0, 0.0],
      inner_loops: face[:inner_loops].map { |loop| loop.map(&:to_a) }
    }
    restored = Query.send(:geometry_face, raw)
    assert_equal [4], restored.fetch(:inner_loops).map(&:length)
    refute Query.send(:point_in_face?, Geom::Point3d.new(0.0, 5.0, 15.0), restored, :x, 0.001)
  end

  def test_snapshot_candidate_is_rejected_if_adjusted_and_original_points_are_in_hole
    face = wall_face(inner_loops: [doorway_hole])
    first = {
      points: face[:points].map(&:to_a),
      normal: [1.0, 0.0, 0.0],
      inner_loops: face[:inner_loops].map { |loop| loop.map(&:to_a) }
    }
    second = first.merge(normal: [-1.0, 0.0, 0.0])
    context = {
      waypoint_snapshot_candidates: [{
        area: 1.0,
        centroid_2d: [5.0, 15.0],
        axis: :x,
        face1: first,
        face2: second
      }]
    }
    state1 = Geom::Point3d.new(0.0, 5.0, 16.0)
    state2 = Geom::Point3d.new(0.0, 5.0, 16.0)
    assert_empty Query.waypoint_candidates_from_snapshot_context(
      context,
      state1_point: state1,
      state2_point: state2,
      tolerance: 0.001
    )
  end

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
