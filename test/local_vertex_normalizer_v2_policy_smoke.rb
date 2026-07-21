# frozen_string_literal: true

# Standalone policy smoke test. This does not require SketchUp and verifies the
# two invariants that caused the v2 review regressions:
#   1. one corner vertex retains independent X/Y/Z plane constraints;
#   2. surface equivalence is independent of a coplanar patch's diagonal.

FakePoint = Struct.new(:x, :y, :z)
FakeVertex = Struct.new(:position, :id)
FakeFace = Struct.new(:record)

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GRID_EPSILON_MM = 0.000001
        MM_PER_INCH = 25.4
        SHORT_EDGE_SLIVER_MIN_ASPECT_RATIO = 20.0
        SHORT_EDGE_SLIVER_THRESHOLD_MM = 1.0
        AXIS_CONSTRAINT_PRIORITY = [2, 1, 0].freeze

        class ReconstructionError < StandardError; end
        class TopologyChangedError < StandardError; end

        def initialize
          @face_class = FakeFace
          @tolerance_mm = 0.001
        end

        def axis_plane_face_record(face) = face.record
        def axis_plane_connected_components(records) = [records]
        def stable_entity_id(entity) = entity.respond_to?(:id) ? entity.id : entity.object_id
        def point_coordinate(point, axis) = [point.x, point.y, point.z][axis]
        def source_point_key(point) = [point.x, point.y, point.z]
        def grid_indices(point) = point.is_a?(Array) ? point : [point.x, point.y, point.z]
        def canonical_edge_key(point_a, point_b) = [point_a, point_b].sort
        def integer_subtract(point_a, point_b)
          [point_a[0] - point_b[0], point_a[1] - point_b[1], point_a[2] - point_b[2]]
        end
        def integer_cross(vector_a, vector_b)
          [
            (vector_a[1] * vector_b[2]) - (vector_a[2] * vector_b[1]),
            (vector_a[2] * vector_b[0]) - (vector_a[0] * vector_b[2]),
            (vector_a[0] * vector_b[1]) - (vector_a[1] * vector_b[0])
          ]
        end
        def integer_dot(vector_a, vector_b)
          vector_a.zip(vector_b).sum { |first, second| first * second }
        end
        def integer_zero_vector?(vector) = vector.all?(&:zero?)
        def integer_triangle_normal(triangle)
          integer_cross(
            integer_subtract(triangle[1], triangle[0]),
            integer_subtract(triangle[2], triangle[0])
          )
        end
        def median_value(values)
          sorted = values.sort
          middle = sorted.length / 2
          sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
        end
        def exact_integer_plane_key(triangle)
          normal = integer_triangle_normal(triangle)
          divisor = normal.map(&:abs).reject(&:zero?).reduce { |gcd, value| gcd.gcd(value) }
          primitive = normal.map { |value| value / divisor }
          primitive = primitive.map(&:-@) if primitive.find { |value| !value.zero? }.negative?
          primitive + [integer_dot(primitive, triangle[0])]
        end
        def exact_boundary_loops(edges)
          adjacency = Hash.new { |hash, key| hash[key] = [] }
          edges.each do |point_a, point_b|
            adjacency[point_a] << point_b
            adjacency[point_b] << point_a
          end
          unused = edges.to_h do |point_a, point_b|
            [canonical_edge_key(point_a, point_b), true]
          end
          loops = []
          until unused.empty?
            start_point, current = unused.keys.first
            previous = start_point
            points = [start_point]
            unused.delete(canonical_edge_key(start_point, current))
            until current == start_point
              points << current
              following = adjacency[current].find do |candidate|
                candidate != previous && unused[canonical_edge_key(current, candidate)]
              end
              following ||= adjacency[current].find do |candidate|
                unused[canonical_edge_key(current, candidate)]
              end
              raise 'Open boundary loop' unless following

              unused.delete(canonical_edge_key(current, following))
              previous, current = current, following
            end
            loops << points
          end
          loops
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/axis_and_triangle_policy_v2'
require_relative '../indoor3d/application/local_vertex_normalizer/rebuild_repair_v2'

normalizer = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer.new
vertex = FakeVertex.new(FakePoint.new(10.0001, 20.0002, 5.0003), 1)
faces = [0, 1, 2].map do |axis|
  FakeFace.new(axis: axis, vertices: [vertex], face: Object.new)
end
plan = normalizer.send(:axis_plane_normalization_plan, faces)
constraints = plan[:constraints].fetch([10.0001, 20.0002, 5.0003])
unless constraints.keys.sort == [0, 1, 2]
  raise "Expected independent X/Y/Z constraints, got #{constraints.inspect}"
end

square_diagonal_ac = [
  { points: [[0, 0, 0], [10, 0, 0], [10, 10, 0]] },
  { points: [[0, 0, 0], [10, 10, 0], [0, 10, 0]] }
]
square_diagonal_bd = [
  { points: [[0, 0, 0], [10, 0, 0], [0, 10, 0]] },
  { points: [[10, 0, 0], [10, 10, 0], [0, 10, 0]] }
]
first = normalizer.send(:normalized_surface_descriptor, square_diagonal_ac)
second = normalizer.send(:normalized_surface_descriptor, square_diagonal_bd)
raise 'Surface descriptor depends on internal diagonal' unless first == second

puts 'LocalVertexNormalizer v2 policy smoke test: OK'
