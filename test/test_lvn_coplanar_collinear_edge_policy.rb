# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/local_vertex_normalizer/coplanar_collinear_edge_policy'
require_relative '../indoor3d/application/local_vertex_normalizer/coplanar_face_component_merge'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerCoplanarCollinearEdgePolicyTest < Minitest::Test
        Policy = CoplanarCollinearEdgePolicy
        Merger = CoplanarFaceComponentMerge
        Point = Struct.new(:x, :y, :z)
        Vector = Struct.new(:x, :y, :z)

        class Vertex
          attr_reader :persistent_id, :position
          attr_accessor :edges

          def initialize(persistent_id, position)
            @persistent_id = persistent_id
            @position = position
            @edges = []
            @valid = true
          end

          def valid?
            @valid
          end

          def invalidate_if_unused!
            @valid = false if @edges.none?(&:valid?)
          end
        end

        class Edge
          attr_reader :persistent_id, :vertices
          attr_accessor :faces

          def initialize(persistent_id, first, second, faces = [])
            @persistent_id = persistent_id
            @vertices = [first, second]
            @faces = faces
            @valid = true
            @vertices.each { |vertex| vertex.edges << self }
          end

          def valid?
            @valid
          end

          def erase!
            return unless @valid

            @valid = false
            @vertices.each do |vertex|
              vertex.edges.delete(self)
              vertex.invalidate_if_unused!
            end
          end
        end

        class Loop
          attr_reader :vertices

          def initialize(vertices)
            @vertices = vertices
          end
        end

        class Face
          attr_reader :persistent_id, :outer_loop, :loops, :normal
          attr_accessor :edges, :material, :back_material, :layer

          def initialize(persistent_id, vertices, normal = Vector.new(0.0, 0.0, 1.0))
            @persistent_id = persistent_id
            @outer_loop = Loop.new(vertices)
            @loops = [@outer_loop]
            @normal = normal
            @edges = []
            @valid = true
          end

          def valid?
            @valid
          end

          def erase!
            return unless @valid

            @valid = false
            @edges.each { |edge| edge.faces.delete(self) }
          end

          def reverse!
            @outer_loop.vertices.reverse!
            @normal = Vector.new(-@normal.x, -@normal.y, -@normal.z)
          end
        end

        class Entities
          attr_reader :faces, :edges, :vertices

          def initialize
            @faces = []
            @edges = []
            @vertices = []
            @next_id = 1
          end

          def add_face(points)
            vertices = points.map { |point| vertex_for(point) }
            face = Face.new(next_id, vertices)
            vertices.each_index do |index|
              first = vertices[index]
              second = vertices[(index + 1) % vertices.length]
              edge = edge_for(first, second) || begin
                created = Edge.new(next_id, first, second)
                @edges << created
                created
              end
              edge.faces << face
              face.edges << edge
            end
            @faces << face
            face
          end

          def grep(klass)
            return @faces.select(&:valid?) if klass == Face
            return @edges.select(&:valid?) if klass == Edge

            []
          end

          private

          def vertex_for(point)
            existing = @vertices.find do |vertex|
              vertex.valid? && point_key(vertex.position) == point_key(point)
            end
            return existing if existing

            vertex = Vertex.new(next_id, point)
            @vertices << vertex
            vertex
          end

          def edge_for(first, second)
            @edges.find do |edge|
              edge.valid? &&
                edge.vertices.include?(first) &&
                edge.vertices.include?(second)
            end
          end

          def point_key(point)
            [point.x.to_f, point.y.to_f, point.z.to_f]
          end

          def next_id
            current = @next_id
            @next_id += 1
            current
          end
        end

        def test_protects_diagonal_at_straight_fan_transition_vertex
          vertex = Vertex.new(1, Point.new(0.0, 0.0, 0.0))
          point_a = Vertex.new(2, Point.new(-1.0, 0.0, 0.0))
          point_c = Vertex.new(3, Point.new(1.0, 0.0, 0.0))
          diagonal_end = Vertex.new(4, Point.new(0.0, 1.0, 0.0))
          branch_end = Vertex.new(5, Point.new(0.0, 0.0, 1.0))
          first = Face.new(10, [])
          second = Face.new(11, [])
          outside_a = Face.new(12, [])
          outside_c = Face.new(13, [])

          diagonal = Edge.new(20, vertex, diagonal_end, [first, second])
          Edge.new(21, vertex, point_a, [first, outside_a])
          Edge.new(22, vertex, point_c, [second, outside_c])
          Edge.new(23, vertex, branch_end, [outside_a, outside_c])

          report = Policy.protected_fan_transition_edges(
            faces: [first, second],
            internal_edges: [diagonal],
            angle_tolerance_deg: 0.001
          )

          assert_equal [diagonal], report[:edges]
          assert_equal [vertex.persistent_id], report[:fan_transition_vertex_ids]
        end

        def test_does_not_protect_diagonal_when_vertex_becomes_degree_two
          vertex = Vertex.new(1, Point.new(0.0, 0.0, 0.0))
          point_a = Vertex.new(2, Point.new(-1.0, 0.0, 0.0))
          point_c = Vertex.new(3, Point.new(1.0, 0.0, 0.0))
          diagonal_end = Vertex.new(4, Point.new(0.0, 1.0, 0.0))
          first = Face.new(10, [])
          second = Face.new(11, [])
          outside = Face.new(12, [])

          diagonal = Edge.new(20, vertex, diagonal_end, [first, second])
          Edge.new(21, vertex, point_a, [first, outside])
          Edge.new(22, vertex, point_c, [second, outside])

          report = Policy.protected_fan_transition_edges(
            faces: [first, second],
            internal_edges: [diagonal],
            angle_tolerance_deg: 0.001
          )

          assert_empty report[:edges]
          assert_empty report[:fan_transition_vertex_ids]
        end

        def test_finds_two_edge_triangular_repair_bundle_at_repeated_outer_vertex
          repeated = Vertex.new(1, Point.new(0.0, 0.0, 0.0))
          before = Vertex.new(2, Point.new(-1.0, 0.0, 0.0))
          wedge_a = Vertex.new(3, Point.new(0.0, 1.0, 0.0))
          wedge_b = Vertex.new(4, Point.new(0.1, 1.0, 0.0))
          after = Vertex.new(5, Point.new(1.0, 0.0, 0.0))
          main = Face.new(10, [before, repeated, wedge_a, wedge_b, repeated, after])
          sliver = Face.new(11, [repeated, wedge_a, wedge_b])
          first = Edge.new(20, repeated, wedge_a, [main, sliver])
          second = Edge.new(21, wedge_b, repeated, [main, sliver])
          main.edges = [first, second]
          sliver.edges = [first, second]

          bundles = Policy.ring_self_touch_repair_edge_bundles(
            faces: [main, sliver],
            internal_edges: [first, second]
          )

          assert_equal 1, bundles.length
          assert_equal [first, second], bundles[0][:edges]
          assert_equal [20, 21], bundles[0][:edge_ids]
          assert_equal [10, 11], bundles[0][:face_ids]
          assert_equal repeated.persistent_id, bundles[0][:repeated_vertex_id]

          repair = Merger.prepare_ring_self_touch_repair(
            [{ faces: [main, sliver], internal_edges: [first, second] }]
          )
          assert_equal [first, second], repair[:edges]
          assert_equal 1, repair[:expected_face_reduction]
          assert_equal 1, Merger.ring_self_touch_vertex_count([main, sliver])
        end

        def test_does_not_repair_two_shared_edges_without_repeated_outer_vertex
          repeated = Vertex.new(1, Point.new(0.0, 0.0, 0.0))
          before = Vertex.new(2, Point.new(-1.0, 0.0, 0.0))
          wedge_a = Vertex.new(3, Point.new(0.0, 1.0, 0.0))
          wedge_b = Vertex.new(4, Point.new(0.1, 1.0, 0.0))
          main = Face.new(10, [before, repeated, wedge_a, wedge_b])
          sliver = Face.new(11, [repeated, wedge_a, wedge_b])
          first = Edge.new(20, repeated, wedge_a, [main, sliver])
          second = Edge.new(21, wedge_b, repeated, [main, sliver])

          bundles = Policy.ring_self_touch_repair_edge_bundles(
            faces: [main, sliver],
            internal_edges: [first, second]
          )

          assert_empty bundles
        end

        def test_finds_existing_straight_fan_transition_for_fast_path_rejection
          vertex = Vertex.new(1, Point.new(0.0, 0.0, 0.0))
          point_a = Vertex.new(2, Point.new(-1.0, 0.0, 0.0))
          point_c = Vertex.new(3, Point.new(1.0, 0.0, 0.0))
          corner = Vertex.new(4, Point.new(0.0, 1.0, 0.0))
          branch_end = Vertex.new(5, Point.new(0.0, 0.0, 1.0))
          face = Face.new(10, [point_a, vertex, point_c, corner])
          outside_a = Face.new(11, [])
          outside_c = Face.new(12, [])
          Edge.new(20, vertex, point_a, [face, outside_a])
          Edge.new(21, vertex, point_c, [face, outside_c])
          Edge.new(22, vertex, branch_end, [outside_a, outside_c])
          entities = Object.new
          entities.define_singleton_method(:grep) do |klass|
            klass == Face ? [face] : []
          end

          result = Policy.fan_transition_vertices(
            entities,
            face_class: Face,
            angle_tolerance_deg: 0.001
          )

          assert_equal [vertex], result
        end

        def test_collapses_degree_two_collinear_vertex_to_one_shared_edge
          entities = Entities.new
          point_a = Point.new(-1.0, 0.0, 0.0)
          middle = Point.new(0.0, 0.0, 0.0)
          point_c = Point.new(1.0, 0.0, 0.0)
          point_d = Point.new(0.0, 1.0, 0.0)
          point_e = Point.new(0.0, 0.0, 1.0)
          entities.add_face([point_a, middle, point_c, point_d])
          entities.add_face([point_c, middle, point_a, point_e])
          middle_vertex = entities.vertices.find do |vertex|
            vertex.position == middle
          end

          report = Policy.collapse_degree_two_collinear_vertices!(
            entities,
            [middle_vertex],
            angle_tolerance_deg: 0.001
          )

          assert_equal 1, report[:collapsed_vertex_count]
          refute middle_vertex.valid?
          shared = entities.edges.find do |edge|
            next false unless edge.valid?

            positions = edge.vertices.map(&:position)
            positions.include?(point_a) && positions.include?(point_c)
          end
          refute_nil shared
          assert_equal 2, shared.faces.length
          assert_equal 2, entities.faces.count(&:valid?)
          refute(
            entities.faces.select(&:valid?).any? do |face|
              face.outer_loop.vertices.any? { |vertex| vertex.position == middle }
            end
          )
        end

        def test_does_not_collapse_merely_near_collinear_degree_two_vertex
          vertex = Vertex.new(1, Point.new(0.0, 1.0e-6, 0.0))
          point_a = Vertex.new(2, Point.new(-1.0, 0.0, 0.0))
          point_c = Vertex.new(3, Point.new(1.0, 0.0, 0.0))
          first = Face.new(10, [])
          second = Face.new(11, [])
          Edge.new(20, vertex, point_a, [first, second])
          Edge.new(21, vertex, point_c, [first, second])

          context = Policy.degree_two_collinear_context(
            vertex,
            angle_tolerance_deg: 0.001
          )

          assert_nil context
        end
      end
    end
  end
end
