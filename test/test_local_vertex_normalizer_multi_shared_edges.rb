# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Edge; end unless const_defined?(:Edge, false)
  class Face; end unless const_defined?(:Face, false)
end

require_relative '../indoor3d/application/local_vertex_normalizer'
require_relative '../indoor3d/application/local_vertex_normalizer/coplanar_shared_edge_groups'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerMultiSharedEdgesTest < Minitest::Test
        Point = Struct.new(:x, :y, :z)
        Vector = Struct.new(:x, :y, :z)
        Vertex = Struct.new(:position)

        class FakeFace
          attr_reader :persistent_id, :normal, :plane, :vertices

          def initialize(persistent_id)
            @persistent_id = persistent_id
            @normal = Vector.new(0.0, 0.0, 1.0)
            @plane = [0.0, 0.0, 1.0, 0.0]
            @vertices = [
              Vertex.new(Point.new(0.0, 0.0, 0.0)),
              Vertex.new(Point.new(1.0, 0.0, 0.0)),
              Vertex.new(Point.new(0.0, 1.0, 0.0))
            ]
            @valid = true
          end

          def valid?
            @valid
          end

          def invalidate!
            @valid = false
          end
        end

        class FakeEdge
          attr_reader :persistent_id, :vertices
          attr_accessor :faces

          def initialize(persistent_id, faces)
            @persistent_id = persistent_id
            @faces = faces
            @vertices = [
              Vertex.new(Point.new(0.0, 0.0, 0.0)),
              Vertex.new(Point.new(1.0, 0.0, 0.0))
            ]
            @valid = true
          end

          def valid?
            @valid
          end

          def invalidate!
            @valid = false
          end

          def reversed_in?(_face)
            false
          end
        end

        class FakeEntities
          attr_reader :erase_calls

          def initialize(faces, edges, reduce_faces: true)
            @faces = faces
            @edges = edges
            @reduce_faces = reduce_faces
            @erase_calls = []
          end

          def grep(klass)
            return @faces.select(&:valid?) if klass == FakeFace
            return @edges.select(&:valid?) if klass == FakeEdge

            []
          end

          def erase_entities(edges)
            @erase_calls << edges.dup
            edges.each(&:invalidate!)
            @faces.last.invalidate! if @reduce_faces
          end
        end

        def test_groups_all_shared_edges_by_unordered_face_pair
          face_a = FakeFace.new(10)
          face_b = FakeFace.new(20)
          edges = [
            FakeEdge.new(101, [face_a, face_b]),
            FakeEdge.new(102, [face_b, face_a]),
            FakeEdge.new(103, [face_a, face_b])
          ]
          entities = FakeEntities.new([face_a, face_b], edges)

          groups = normalizer.send(
            :coplanar_shared_edge_groups,
            entities,
            plane_tolerance_mm: 0.001,
            angle_tolerance_deg: 0.001
          )

          assert_equal 1, groups.length
          assert_equal [:pair, 10, 20], groups.first[:key]
          assert_equal 3, groups.first[:edges].length
        end

        def test_removes_multiple_shared_edges_with_one_atomic_erase
          face_a = FakeFace.new(10)
          face_b = FakeFace.new(20)
          edges = [
            FakeEdge.new(101, [face_a, face_b]),
            FakeEdge.new(102, [face_a, face_b]),
            FakeEdge.new(103, [face_a, face_b])
          ]
          entities = FakeEntities.new([face_a, face_b], edges)

          report = normalizer.send(
            :remove_coplanar_shared_edges,
            entities,
            plane_tolerance_mm: 0.001,
            angle_tolerance_deg: 0.001
          )

          assert_equal 1, entities.erase_calls.length
          assert_equal 3, entities.erase_calls.first.length
          assert_equal 3, report[:removed_edges]
          assert_equal 1, report[:removed_groups]
          assert_equal 1, report[:multi_edge_group_count]
          assert_equal 3, report[:max_shared_edges_per_group]
        end

        def test_rejects_group_when_distinct_faces_do_not_merge
          face_a = FakeFace.new(10)
          face_b = FakeFace.new(20)
          edges = [
            FakeEdge.new(101, [face_a, face_b]),
            FakeEdge.new(102, [face_a, face_b])
          ]
          entities = FakeEntities.new(
            [face_a, face_b],
            edges,
            reduce_faces: false
          )

          assert_raises(LocalVertexNormalizer::DestructiveCoplanarCleanupError) do
            normalizer.send(
              :remove_coplanar_shared_edges,
              entities,
              plane_tolerance_mm: 0.001,
              angle_tolerance_deg: 0.001
            )
          end
        end

        private

        def normalizer
          LocalVertexNormalizer.new(
            edge_class: FakeEdge,
            face_class: FakeFace
          )
        end
      end
    end
  end
end
