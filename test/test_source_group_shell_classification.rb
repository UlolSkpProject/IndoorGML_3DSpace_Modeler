# frozen_string_literal: true

require 'minitest/autorun'

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
      end
    end
  end
end
