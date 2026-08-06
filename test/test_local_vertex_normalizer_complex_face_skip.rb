# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Edge; end unless const_defined?(:Edge, false)
  class Face; end unless const_defined?(:Face, false)
end

require_relative '../indoor3d/application/local_vertex_normalizer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerComplexFaceSkipTest < Minitest::Test
        Point = Struct.new(:x, :y, :z)
        Vertex = Struct.new(:position)
        Loop = Struct.new(:vertices)

        class FakeFace
          attr_reader :loops, :outer_loop, :persistent_id

          def initialize(loop_vertex_counts, persistent_id: 100)
            @loops = loop_vertex_counts.map.with_index do |count, loop_index|
              vertices = count.times.map do |index|
                Vertex.new(
                  Point.new(
                    (loop_index * 10_000) + index.to_f,
                    loop_index.to_f,
                    0.0
                  )
                )
              end
              Loop.new(vertices)
            end
            @outer_loop = @loops.first
            @persistent_id = persistent_id
          end

          def valid?
            true
          end
        end

        class FakeEdge; end

        class FakeEntities
          def initialize(faces)
            @faces = faces
          end

          def grep(klass)
            return @faces if klass == FakeFace
            return [] if klass == FakeEdge

            []
          end
        end

        Definition = Struct.new(:entities)

        class FakeEntity
          attr_reader :definition, :name, :persistent_id

          def initialize(faces)
            @definition = Definition.new(FakeEntities.new(faces))
            @name = 'complex-solid'
            @persistent_id = 42
          end

          def valid?
            true
          end

          def manifold?
            true
          end

          def volume
            1.0
          end
        end

        class FakeModel
          attr_reader :calls

          def initialize
            @calls = []
          end

          def start_operation(*arguments)
            @calls << [:start_operation, arguments]
            true
          end

          def commit_operation
            @calls << [:commit_operation]
            true
          end

          def abort_operation
            @calls << [:abort_operation]
            true
          end
        end

        def test_complex_face_skips_before_operation_and_preserves_geometry
          model = FakeModel.new
          entity = FakeEntity.new([FakeFace.new([513])])
          instance = normalizer(model)
          instance.define_singleton_method(:validate_entity!) { |_entity| true }

          result = instance.normalize(entity)

          assert_equal true, result[:normalization_skipped]
          assert_equal false, result[:normalization_complete]
          assert_equal :complex_face_complexity_limit, result[:skip_reason]
          assert_equal :solid, result[:skip_scope]
          assert_equal true, result[:geometry_unchanged]
          assert_equal result[:topology_before], result[:topology_after]
          assert_equal 1, result[:complex_face_count]
          assert_equal 513, result.dig(:complex_faces, 0, :weak_vertex_count)
          assert_includes result.dig(:complex_faces, 0, :reasons),
                          :weak_vertex_limit
          assert_empty model.calls
        end

        def test_face_at_limit_uses_existing_normalization_path
          entity = FakeEntity.new([FakeFace.new([512])])
          instance = normalizer(nil)
          instance.define_singleton_method(:validate_entity!) { |_entity| true }
          instance.define_singleton_method(:normalize_entity) do |_entity|
            :existing_normalization_path
          end

          result = instance.normalize(entity, manage_operation: false)

          assert_equal :existing_normalization_path, result
        end

        def test_diagnostic_profile_reports_skipped_instead_of_success
          model = FakeModel.new
          entity = FakeEntity.new([FakeFace.new([513])])
          instance = normalizer(model)
          instance.define_singleton_method(:validate_entity!) { |_entity| true }

          output, = capture_io do
            @result = instance.normalize(entity, diagnostics: true)
          end

          assert_equal :skipped, @result.dig(:diagnostic_profile, :status)
          assert_equal true,
                       @result.dig(:diagnostic_profile, :normalization_skipped)
          assert_match(/\[LVN DIAGNOSTIC\] PROFILE SKIPPED/, output)
          assert_empty model.calls
        ensure
          @result = nil
        end

        private

        def normalizer(model)
          LocalVertexNormalizer.new(
            LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            face_class: FakeFace,
            edge_class: FakeEdge,
            model: model
          )
        end
      end
    end
  end
end
