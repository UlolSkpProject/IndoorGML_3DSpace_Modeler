# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/precision_validation/lvn_state'

module Sketchup
  class Edge; end
  class Face; end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationLvnStateTest < Minitest::Test
        Point = Struct.new(:x, :y, :z)
        Vector = Struct.new(:x, :y, :z)
        Vertex = Struct.new(:position)

        class Edge < Sketchup::Edge
          attr_reader :vertices

          def initialize(*vertices)
            @vertices = vertices
          end
        end

        class Loop
          attr_reader :vertices

          def initialize(vertices)
            @vertices = vertices
          end
        end

        class Face < Sketchup::Face
          attr_reader :loops, :outer_loop, :normal

          def initialize(vertices)
            @outer_loop = Loop.new(vertices)
            @loops = [@outer_loop]
            @normal = Vector.new(0.0, 0.0, 1.0)
          end

          def vertices
            @outer_loop.vertices
          end
        end

        Definition = Struct.new(:entities, :guid)

        class Group
          attr_reader :definition
          attr_accessor :transformation

          def initialize(definition)
            @definition = definition
            @attributes = {}
            @transformation = :identity
          end

          def valid?
            true
          end

          def get_attribute(dictionary, key, default = nil)
            @attributes.fetch([dictionary, key], default)
          end

          def set_attribute(dictionary, key, value)
            @attributes[[dictionary, key]] = value
          end

          def delete_attribute(dictionary, key)
            @attributes.delete([dictionary, key])
          end
        end

        def setup
          @v1 = Vertex.new(Point.new(0.0, 0.0, 0.0))
          @v2 = Vertex.new(Point.new(1.0, 0.0, 0.0))
          @v3 = Vertex.new(Point.new(0.0, 1.0, 0.0))
          entities = [
            Edge.new(@v1, @v2),
            Edge.new(@v2, @v3),
            Edge.new(@v3, @v1),
            Face.new([@v1, @v2, @v3])
          ]
          @group = Group.new(Definition.new(entities, 'definition-guid'))
        end

        def test_false_is_written_explicitly_for_new_cell_space
          assert PrecisionValidation::LvnState.set_failed(@group, false)
          assert_equal false,
                       @group.get_attribute('IndoorGml', 'lvn_failed')
          refute PrecisionValidation::LvnState.failed?(@group)
        end

        def test_failure_persists_only_lvn_failed_flag
          assert PrecisionValidation::LvnState.set_failed(@group, true)

          assert PrecisionValidation::LvnState.failed?(@group)
          assert_nil @group.get_attribute(
            'IndoorGml',
            'lvn_failed_geometry_signature'
          )
          assert_nil PrecisionValidation::LvnState.failure_signature(@group)
          assert PrecisionValidation::LvnState.failed_and_unchanged?(@group)
        end

        def test_local_geometry_change_does_not_implicitly_clear_failure_flag
          PrecisionValidation::LvnState.set_failed(@group, true)
          @v2.position = Point.new(1.001, 0.0, 0.0)

          refute PrecisionValidation::LvnState.geometry_changed_since_failure?(@group)
          assert PrecisionValidation::LvnState.failed_and_unchanged?(@group)
        end

        def test_transient_geometry_signature_tracks_local_geometry_only
          before = PrecisionValidation::LvnState.geometry_signature(@group)
          @group.transformation = :translated_and_rotated

          assert_equal before,
                       PrecisionValidation::LvnState.geometry_signature(@group)

          @v2.position = Point.new(1.001, 0.0, 0.0)

          refute_equal before,
                       PrecisionValidation::LvnState.geometry_signature(@group)
        end

        def test_setting_failure_removes_legacy_signature
          @group.set_attribute(
            'IndoorGml',
            'lvn_failed_geometry_signature',
            'legacy-signature'
          )

          assert PrecisionValidation::LvnState.set_failed(@group, true)
          assert_equal true, @group.get_attribute('IndoorGml', 'lvn_failed')
          assert_nil @group.get_attribute(
            'IndoorGml',
            'lvn_failed_geometry_signature'
          )
        end

        def test_success_clears_flag_and_legacy_signature
          PrecisionValidation::LvnState.set_failed(@group, true)
          @group.set_attribute(
            'IndoorGml',
            'lvn_failed_geometry_signature',
            'legacy-signature'
          )

          assert PrecisionValidation::LvnState.set_failed(@group, false)

          assert_equal false,
                       @group.get_attribute('IndoorGml', 'lvn_failed')
          assert_nil @group.get_attribute(
            'IndoorGml',
            'lvn_failed_geometry_signature'
          )
        end
      end
    end
  end
end
