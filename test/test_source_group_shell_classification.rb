# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Edge; end unless const_defined?(:Edge, false)
end

require_relative '../indoor3d/utils/geometry/source_group'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        class SourceGroupShellClassificationTest < Minitest::Test
          Vertex = Struct.new(:position)
          Loop = Struct.new(:vertices)

          class Face
            attr_reader :outer_loop

            def initialize(point)
              @outer_loop = Loop.new([Vertex.new(point)])
            end

            def valid?
              true
            end
          end

          def test_classifies_one_outer_shell_and_multiple_cavities
            outer = [Face.new(:outer_point)]
            cavity1 = [Face.new(:cavity1_point)]
            cavity2 = [Face.new(:cavity2_point)]
            contains = {
              [outer.object_id, :cavity1_point] => true,
              [outer.object_id, :cavity2_point] => true
            }

            result = classify([cavity1, outer, cavity2], contains)

            assert result[:valid]
            assert_same outer, result[:exterior_faces]
            assert_equal [cavity1, cavity2], result[:interior_face_components]
          end

          def test_rejects_multiple_disconnected_exterior_shells
            first = [Face.new(:first)]
            second = [Face.new(:second)]

            result = classify([first, second], {})

            refute result[:valid]
            assert_includes result[:reason], 'Disconnected or nested solid shells'
          end

          def test_rejects_solid_island_nested_inside_cavity
            outer = [Face.new(:outer_point)]
            cavity = [Face.new(:cavity_point)]
            island = [Face.new(:island_point)]
            contains = {
              [outer.object_id, :cavity_point] => true,
              [outer.object_id, :island_point] => true,
              [cavity.object_id, :island_point] => true
            }

            result = classify([outer, cavity, island], contains)

            refute result[:valid]
            assert_includes result[:reason], 'Disconnected or nested solid shells'
          end

          private

          def classify(components, contains)
            singleton = Geometry.singleton_class
            original = Geometry.method(:shell_contains_point_in_faces?) if Geometry.respond_to?(:shell_contains_point_in_faces?)
            singleton.send(:define_method, :shell_contains_point_in_faces?) do |faces, point, *_args|
              contains.fetch([faces.object_id, point], false)
            end
            Geometry.send(:classify_shell_components, components)
          ensure
            if original
              singleton.send(:define_method, :shell_contains_point_in_faces?, original)
            else
              singleton.send(:remove_method, :shell_contains_point_in_faces?)
            end
          end
        end

        class CellSpaceEdgeRenderingTest < Minitest::Test
          class Edge < Sketchup::Edge
            attr_accessor :hidden, :soft, :smooth

            def initialize(hidden: false, soft: false, smooth: false, valid: true)
              @hidden = hidden
              @soft = soft
              @smooth = smooth
              @valid = valid
            end

            def valid?
              @valid
            end

            def hidden?
              @hidden
            end

            def soft?
              @soft
            end

            def smooth?
              @smooth
            end
          end

          Definition = Struct.new(:entities) do
            def valid?
              true
            end
          end

          Group = Struct.new(:definition)

          def test_makes_hidden_soft_and_smooth_edges_solid
            styled = Edge.new(hidden: true, soft: true, smooth: true)
            hard = Edge.new
            invalid = Edge.new(hidden: true, soft: true, smooth: true, valid: false)
            group = Group.new(Definition.new([styled, hard, invalid, Object.new]))

            changed_count = Geometry.make_cell_space_edges_solid!(group)

            assert_equal 1, changed_count
            refute styled.hidden?
            refute styled.soft?
            refute styled.smooth?
            refute hard.hidden?
            refute hard.soft?
            refute hard.smooth?
            assert invalid.hidden?
            assert invalid.soft?
            assert invalid.smooth?
          end

          def test_returns_zero_for_group_without_valid_definition
            group = Group.new(Struct.new(:entities) do
              def valid?
                false
              end
            end.new([]))

            assert_equal 0, Geometry.make_cell_space_edges_solid!(group)
          end
        end
      end
    end
  end
end
