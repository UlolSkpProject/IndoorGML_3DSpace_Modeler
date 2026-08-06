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
      class LocalVertexNormalizerSourceBoundaryTriangleFastPathTest < Minitest::Test
        Point = Struct.new(:x, :y, :z)
        Vector = Struct.new(:x, :y, :z)
        Vertex = Struct.new(:position)
        Loop = Struct.new(:vertices)

        class FakeFace
          attr_reader :loops, :normal, :material, :back_material, :layer

          def initialize(
            loop_points,
            normal: Vector.new(0.0, 0.0, 1.0),
            extra_loops: [],
            material: :front,
            back_material: :back,
            layer: :layer
          )
            @loops = [build_loop(loop_points)] +
              extra_loops.map { |points| build_loop(points) }
            @normal = normal
            @material = material
            @back_material = back_material
            @layer = layer
          end

          private

          def build_loop(points)
            Loop.new(points.map { |point| Vertex.new(point) })
          end
        end

        class ProbeNormalizer < LocalVertexNormalizer
          attr_reader :classification_calls

          private

          def classify_exact_patch_loops(*arguments)
            @classification_calls = @classification_calls.to_i + 1
            super
          end
        end

        def test_exact_triangle_matches_legacy_record_contract
          face = FakeFace.new(
            [
              Point.new(0.0, 0.0, 0.0),
              Point.new(2.0, 0.0, 0.0),
              Point.new(0.0, 1.0, 0.0)
            ]
          )
          subject = normalizer

          fast_records = subject.send(
            :source_boundary_triangle_records,
            face,
            501
          )
          legacy_records = triangle_fast_path_method(subject)
                           .super_method
                           .call(face, 501)

          assert_equal 1, fast_records.length
          assert_equal 1, legacy_records.length
          assert_equal canonical_points(legacy_records.first),
                       canonical_points(fast_records.first)
          assert_equal record_metadata(legacy_records.first),
                       record_metadata(fast_records.first)
        end

        def test_exact_triangle_skips_polygon_classification
          face = FakeFace.new(
            [
              Point.new(0.0, 0.0, 0.0),
              Point.new(1.0, 0.0, 0.0),
              Point.new(0.0, 1.0, 0.0)
            ]
          )
          subject = probe_normalizer

          records = subject.send(
            :source_boundary_triangle_records,
            face,
            502
          )

          assert_equal 1, records.length
          assert_equal 0, subject.classification_calls.to_i
        end

        def test_reversed_boundary_is_aligned_to_face_normal
          face = FakeFace.new(
            [
              Point.new(0.0, 0.0, 0.0),
              Point.new(0.0, 1.0, 0.0),
              Point.new(1.0, 0.0, 0.0)
            ],
            normal: Vector.new(0.0, 0.0, 1.0)
          )

          record = normalizer.send(
            :source_boundary_triangle_records,
            face,
            503
          ).first

          assert_operator orientation_dot(record), :>, 0.0
          assert_equal 0, record[:source_polygon_index]
          assert_equal true, record[:source_boundary_snapshot]
        end

        def test_non_triangle_boundary_uses_legacy_path
          face = FakeFace.new(
            [
              Point.new(0.0, 0.0, 0.0),
              Point.new(2.0, 0.0, 0.0),
              Point.new(2.0, 1.0, 0.0),
              Point.new(0.0, 1.0, 0.0)
            ]
          )
          subject = probe_normalizer

          records = subject.send(
            :source_boundary_triangle_records,
            face,
            504
          )

          assert_operator subject.classification_calls.to_i, :>, 0
          assert_equal 2, records.length
        end

        def test_source_precision_degenerate_triangle_is_not_accepted
          face = FakeFace.new(
            [
              Point.new(0.0, 0.0, 0.0),
              Point.new(1.0e-10, 0.0, 0.0),
              Point.new(0.0, 1.0, 0.0)
            ]
          )

          assert_raises(LocalVertexNormalizer::ReconstructionError) do
            normalizer.send(
              :source_boundary_triangle_records,
              face,
              505
            )
          end
        end

        def test_source_boundary_normalization_remains_outside_shortcut
          ancestors = LocalVertexNormalizer.ancestors
          normalization_index = ancestors.index(
            LocalVertexNormalizerSourceBoundaryNormalization
          )
          shortcut_index = ancestors.index(
            LocalVertexNormalizerSourceBoundaryTriangleFastPath
          )

          refute_nil normalization_index
          refute_nil shortcut_index
          assert_operator normalization_index, :<, shortcut_index
        end

        private

        def normalizer
          build_normalizer(LocalVertexNormalizer)
        end

        def probe_normalizer
          build_normalizer(ProbeNormalizer)
        end

        def build_normalizer(klass)
          klass.new(
            0.001,
            point_factory: ->(x, y, z) { Point.new(x, y, z) },
            vector_factory: ->(x, y, z) { Vector.new(x, y, z) },
            edge_class: Sketchup::Edge,
            face_class: Sketchup::Face
          )
        end

        def triangle_fast_path_method(subject)
          method = subject.method(:source_boundary_triangle_records)
          while method &&
                method.owner !=
                  LocalVertexNormalizerSourceBoundaryTriangleFastPath
            method = method.super_method
          end
          refute_nil method
          method
        end

        def canonical_points(record)
          record.fetch(:points).map do |point|
            [point.x.to_f, point.y.to_f, point.z.to_f]
          end.sort
        end

        def record_metadata(record)
          record.reject { |key, _value| key == :points }
        end

        def orientation_dot(record)
          points = record.fetch(:points)
          edge_a = [
            points[1].x.to_f - points[0].x.to_f,
            points[1].y.to_f - points[0].y.to_f,
            points[1].z.to_f - points[0].z.to_f
          ]
          edge_b = [
            points[2].x.to_f - points[0].x.to_f,
            points[2].y.to_f - points[0].y.to_f,
            points[2].z.to_f - points[0].z.to_f
          ]
          cross = [
            (edge_a[1] * edge_b[2]) - (edge_a[2] * edge_b[1]),
            (edge_a[2] * edge_b[0]) - (edge_a[0] * edge_b[2]),
            (edge_a[0] * edge_b[1]) - (edge_a[1] * edge_b[0])
          ]
          normal = record.fetch(:source_normal)
          (cross[0] * normal[0]) +
            (cross[1] * normal[1]) +
            (cross[2] * normal[2])
        end
      end
    end
  end
end
