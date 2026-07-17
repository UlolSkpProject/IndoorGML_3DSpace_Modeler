# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/local_vertex_normalizer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerTest < Minitest::Test
        FakePoint = Struct.new(:x, :y, :z)

        def test_default_tolerance_is_001_mm
          assert_equal 0.001, LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
        end

        def test_normalized_target_rounds_each_local_coordinate
          target = normalizer.send(:normalized_target, point_mm(1.234, -2.345, 3.456))

          assert_in_delta 1.234, target.x * 25.4, 0.0000001
          assert_in_delta(-2.345, target.y * 25.4, 0.0000001)
          assert_in_delta 3.456, target.z * 25.4, 0.0000001
        end

        def test_unique_grid_key_coalesces_coincident_normalized_points
          first = normalizer.send(:normalized_target, point_mm(0.001, 0.001, 0.001))
          second = normalizer.send(:normalized_target, point_mm(0.0014, 0.0014, 0.0014))

          assert_equal normalizer.send(:grid_indices, first), normalizer.send(:grid_indices, second)
        end

        def test_point_on_segment_detects_only_interior_collinear_point
          start_point = point_mm(0, 0, 0)
          end_point = point_mm(10, 0, 0)

          parameter = normalizer.send(:point_on_segment_parameter, point_mm(4, 0, 0), start_point, end_point, 0.000001)
          off_line = normalizer.send(:point_on_segment_parameter, point_mm(4, 0.001, 0), start_point, end_point, 0.000001)

          assert_in_delta 0.4, parameter, 0.0000001
          assert_nil off_line
        end

        def test_collinear_triangle_is_skipped
          points = [point_mm(0, 0, 0), point_mm(5, 0, 0), point_mm(10, 0, 0)]
          non_collinear = [point_mm(0, 0, 0), point_mm(5, 1, 0), point_mm(10, 0, 0)]

          assert normalizer.send(:collinear_triangle?, points)
          refute normalizer.send(:collinear_triangle?, non_collinear)
        end

        def test_normalized_predicate_accepts_unique_vertices_on_grid
          entity = fake_entity([
            point_mm(0, 0, 0),
            point_mm(10.01, 0, 0),
            point_mm(0, 20.02, 0)
          ])

          assert normalizer_with_geometry.normalized?(entity)
        end

        def test_normalized_predicate_rejects_off_grid_vertex
          entity = fake_entity([
            point_mm(0, 0, 0),
            point_mm(10.0104, 0, 0),
            point_mm(0, 20.02, 0)
          ])

          refute normalizer_with_geometry.normalized?(entity)
        end

        def test_normalized_predicate_rejects_topologically_distinct_coincident_vertices
          entity = fake_entity([
            point_mm(0, 0, 0),
            point_mm(10.01, 0, 0),
            point_mm(10.01, 0, 0)
          ])

          refute normalizer_with_geometry.normalized?(entity)
        end

        def test_non_positive_tolerance_is_rejected
          assert_raises(ArgumentError) { LocalVertexNormalizer.new(0) }
          assert_raises(ArgumentError) { LocalVertexNormalizer.new(-0.01) }
        end

        private

        def normalizer(tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM)
          LocalVertexNormalizer.new(
            tolerance_mm,
            point_factory: ->(x, y, z) { FakePoint.new(x, y, z) },
            edge_class: Class.new,
            face_class: Class.new
          )
        end

        class FakeVertex
          attr_reader :position

          def initialize(position)
            @position = position
          end
        end
        FakeEdge = Struct.new(:vertices)

        class FakeEntities
          def initialize(vertices)
            @edges = vertices.each_slice(2).map { |pair| FakeEdge.new(pair) }
            @edges << FakeEdge.new([vertices.last, vertices.first]) if vertices.length.odd?
          end

          def grep(klass)
            klass == FakeEdge ? @edges : []
          end
        end

        FakeDefinition = Struct.new(:entities) do
          def valid?
            true
          end
        end

        FakeEntity = Struct.new(:definition) do
          def valid?
            true
          end
        end

        def normalizer_with_geometry
          LocalVertexNormalizer.new(
            LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            point_factory: ->(x, y, z) { FakePoint.new(x, y, z) },
            edge_class: FakeEdge,
            face_class: Class.new
          )
        end

        def fake_entity(points)
          vertices = points.map { |point| FakeVertex.new(point) }
          FakeEntity.new(FakeDefinition.new(FakeEntities.new(vertices)))
        end

        def point_mm(x, y, z)
          FakePoint.new(x / 25.4, y / 25.4, z / 25.4)
        end
      end
    end
  end
end
