# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Edge; end unless const_defined?(:Edge, false)
  class Face; end unless const_defined?(:Face, false)
end

require_relative '../indoor3d/application/local_vertex_normalizer/geometry_kernel'
require_relative '../indoor3d/application/local_vertex_normalizer/coplanar_face_component_merge'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerGeometryCountsContractTest < Minitest::Test
        class TestVertex; end
        class TestFace < Sketchup::Face; end

        class TestEdge < Sketchup::Edge
          attr_reader :vertices, :faces

          def initialize(vertices:, faces:, reversed_by_face: {})
            @vertices = vertices
            @faces = faces
            @reversed_by_face = reversed_by_face
          end

          def reversed_in?(face)
            @reversed_by_face.fetch(face, false)
          end
        end

        class TestEntities
          def initialize(faces:, edges:)
            @faces = faces
            @edges = edges
          end

          def grep(klass)
            return @faces if klass == TestFace
            return @edges if klass == TestEdge

            []
          end
        end

        def setup
          @normalizer = LocalVertexNormalizer.new(
            0.001,
            point_factory: ->(*_args) { nil },
            vector_factory: ->(*_args) { nil },
            edge_class: TestEdge,
            face_class: TestFace,
            model: Object.new
          )
        end

        def test_geometry_counts_contract_is_owned_by_local_vertex_normalizer
          assert_equal(
            LocalVertexNormalizer,
            LocalVertexNormalizer.instance_method(:geometry_counts).owner
          )
          refute_includes LocalVertexNormalizer.ancestors, CoplanarFaceComponentMerge
          refute_respond_to CoplanarFaceComponentMerge, :geometry_counts
          assert_respond_to CoplanarFaceComponentMerge, :coplanar_merge_face_summary
        end

        def test_geometry_counts_reports_vertices_wire_edges_and_orientation_conflicts
          face_a = TestFace.new
          face_b = TestFace.new
          vertices = Array.new(4) { TestVertex.new }
          conflicting_edge = TestEdge.new(
            vertices: vertices[0, 2],
            faces: [face_a, face_b],
            reversed_by_face: { face_a => false, face_b => false }
          )
          wire_edge = TestEdge.new(vertices: vertices[2, 2], faces: [])
          entities = TestEntities.new(
            faces: [face_a, face_b],
            edges: [conflicting_edge, wire_edge]
          )

          counts = @normalizer.send(:geometry_counts, entities)

          assert_equal 4, counts[:vertices]
          assert_equal 1, counts[:wire_edges]
          assert_equal 1, counts[:orientation_conflicts]
          refute @normalizer.send(:closed_surface?, counts)
          assert_equal 1, @normalizer.send(:topology_anomaly_score, counts)
        end

        def test_orientation_conflict_alone_fails_closed_topology
          topology = {
            faces: 2,
            edges: 3,
            vertices: 3,
            boundary_edges: 0,
            wire_edges: 0,
            overused_edges: 0,
            orientation_conflicts: 1
          }

          assert @normalizer.send(:closed_surface?, topology)
          refute @normalizer.send(:closed_topology?, topology)
        end
      end
    end
  end
end
