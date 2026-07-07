# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Face; end unless const_defined?(:Face, false)
  class Edge; end unless const_defined?(:Edge, false)
  class Group; end unless const_defined?(:Group, false)
  class ComponentInstance; end unless const_defined?(:ComponentInstance, false)
  class ConstructionPoint; end unless const_defined?(:ConstructionPoint, false)

  class << self
    attr_accessor :test_active_model
  end

  def self.active_model
    @test_active_model
  end
end

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Transformation
        def self.root_transformation_in_model(root_group)
          root_group.transformation
        end unless respond_to?(:root_transformation_in_model)
      end
    end

    module IndoorCore
      class IndoorModel
      end

      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/application/indoor_model/primal_normalization'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrimalNormalizationTest < Minitest::Test
        def teardown
          Sketchup.test_active_model = nil
        end

        def test_raw_face_is_recreated_in_root_wrapper_and_source_geometry_is_erased
          transform = FakeTransformation.new(10, 20, 30)
          edges = [
            FakeEdge.new([point(0, 0, 0), point(1, 0, 0)]),
            FakeEdge.new([point(1, 0, 0), point(1, 1, 0)]),
            FakeEdge.new([point(1, 1, 0), point(0, 1, 0)]),
            FakeEdge.new([point(0, 1, 0), point(0, 0, 0)])
          ]
          face = FakeFace.new([point(0, 0, 0), point(1, 0, 0), point(1, 1, 0), point(0, 1, 0)], edges: edges)
          edges.each { |edge| edge.faces = [face] }
          model = FakeModel.new
          Sketchup.test_active_model = model
          normalizer = FakeIndoorModel.new(FakePrimalGroup.new(transform))

          normalizer.move_raw([face] + edges)

          wrapper = model.entities.created_groups.first
          assert_equal 'Unconverted Geometry', wrapper.name
          assert_equal [[point(10, 20, 30), point(11, 20, 30), point(11, 21, 30), point(10, 21, 30)]], wrapper.entities.faces
          assert face.erased?
          assert edges.all?(&:erased?)
        end

        def test_standalone_raw_edge_is_recreated_in_root_wrapper
          edge = FakeEdge.new([point(2, 3, 4), point(5, 6, 7)])
          model = FakeModel.new
          Sketchup.test_active_model = model
          normalizer = FakeIndoorModel.new(FakePrimalGroup.new(FakeTransformation.new(1, 1, 1)))

          normalizer.move_raw([edge])

          wrapper = model.entities.created_groups.first
          assert_equal [[point(3, 4, 5), point(6, 7, 8)]], wrapper.entities.lines
          assert edge.erased?
        end

        def test_raw_face_inner_loop_is_recreated_as_hole
          outer_edges = [
            FakeEdge.new([point(0, 0, 0), point(4, 0, 0)]),
            FakeEdge.new([point(4, 0, 0), point(4, 4, 0)]),
            FakeEdge.new([point(4, 4, 0), point(0, 4, 0)]),
            FakeEdge.new([point(0, 4, 0), point(0, 0, 0)])
          ]
          inner_edges = [
            FakeEdge.new([point(1, 1, 0), point(2, 1, 0)]),
            FakeEdge.new([point(2, 1, 0), point(2, 2, 0)]),
            FakeEdge.new([point(2, 2, 0), point(1, 2, 0)]),
            FakeEdge.new([point(1, 2, 0), point(1, 1, 0)])
          ]
          face = FakeFace.new(
            [point(0, 0, 0), point(4, 0, 0), point(4, 4, 0), point(0, 4, 0)],
            edges: outer_edges + inner_edges,
            inner_loops: [[point(1, 1, 0), point(2, 1, 0), point(2, 2, 0), point(1, 2, 0)]]
          )
          (outer_edges + inner_edges).each { |edge| edge.faces = [face] }
          model = FakeModel.new
          Sketchup.test_active_model = model
          normalizer = FakeIndoorModel.new(FakePrimalGroup.new(FakeTransformation.new(10, 0, 0)))

          normalizer.move_raw([face] + outer_edges + inner_edges)

          wrapper = model.entities.created_groups.first
          assert_equal [
            [point(10, 0, 0), point(14, 0, 0), point(14, 4, 0), point(10, 4, 0)],
            [point(11, 1, 0), point(12, 1, 0), point(12, 2, 0), point(11, 2, 0)]
          ], wrapper.entities.faces
          assert_equal false, wrapper.entities.copied_faces[0].erased?
          assert_equal true, wrapper.entities.copied_faces[1].erased?
          assert face.erased?
          assert (outer_edges + inner_edges).all?(&:erased?)
        end

        private

        def point(x, y, z)
          FakePoint.new(x, y, z)
        end

        class FakeIndoorModel
          include IndoorModel::PrimalNormalization

          def initialize(primal_group)
            @primal_group = primal_group
          end

          def move_raw(entities)
            move_raw_primal_entities_to_root(entities)
          end
        end

        class FakeModel
          attr_reader :entities

          def initialize
            @entities = FakeEntities.new
          end

          def active_path
            nil
          end
        end

        class FakePrimalGroup
          attr_reader :transformation

          def initialize(transformation)
            @transformation = transformation
          end

          def valid?
            true
          end
        end

        class FakeTransformation
          def initialize(dx, dy, dz)
            @dx = dx
            @dy = dy
            @dz = dz
          end

          def apply(point)
            FakePoint.new(point.x + @dx, point.y + @dy, point.z + @dz)
          end
        end

        class FakePoint
          attr_reader :x, :y, :z

          def initialize(x, y, z)
            @x = x
            @y = y
            @z = z
          end

          def transform(transformation)
            transformation.apply(self)
          end

          def ==(other)
            other.is_a?(FakePoint) && [x, y, z] == [other.x, other.y, other.z]
          end
        end

        class FakeVertex
          attr_reader :position

          def initialize(position)
            @position = position
          end
        end

        class FakeLoop
          attr_reader :vertices

          def initialize(points)
            @vertices = points.map { |position| FakeVertex.new(position) }
          end
        end

        class FakeFace < Sketchup::Face
          attr_accessor :material, :back_material
          attr_reader :outer_loop, :edges, :loops

          def initialize(points, edges:, inner_loops: [])
            @outer_loop = FakeLoop.new(points)
            @loops = [@outer_loop] + inner_loops.map { |loop_points| FakeLoop.new(loop_points) }
            @edges = edges
            @valid = true
          end

          def valid?
            @valid == true
          end

          def erase!
            @valid = false
          end

          def erased?
            !valid?
          end
        end

        class FakeEdge < Sketchup::Edge
          attr_accessor :faces

          def initialize(points)
            @vertices = points.map { |position| FakeVertex.new(position) }
            @faces = []
            @valid = true
          end

          attr_reader :vertices

          def valid?
            @valid == true
          end

          def erase!
            @valid = false
          end

          def erased?
            !valid?
          end
        end

        class FakeGroup < Sketchup::Group
          attr_accessor :name
          attr_reader :entities

          def initialize
            @entities = FakeEntities.new
            @valid = true
          end

          def valid?
            @valid == true
          end

          def erase!
            @valid = false
          end
        end

        class FakeCopiedFace
          attr_accessor :material, :back_material

          def initialize
            @valid = true
          end

          def valid?
            @valid == true
          end

          def erase!
            @valid = false
          end

          def erased?
            !valid?
          end
        end

        class FakeEntities
          attr_reader :created_groups, :faces, :lines, :copied_faces

          def initialize
            @created_groups = []
            @faces = []
            @lines = []
            @copied_faces = []
          end

          def add_group
            group = FakeGroup.new
            @created_groups << group
            group
          end

          def add_face(points)
            @faces << points
            FakeCopiedFace.new.tap { |face| @copied_faces << face }
          end

          def add_line(point1, point2)
            @lines << [point1, point2]
            FakeEdge.new([point1, point2])
          end

          def to_a
            faces + lines
          end
        end
      end
    end
  end
end
