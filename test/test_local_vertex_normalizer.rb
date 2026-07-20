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
      class LocalVertexNormalizerTest < Minitest::Test
        Point = Struct.new(:x, :y, :z)

        class FakeMesh
          attr_reader :polygons

          def initialize(points, polygons = nil)
            @points = points
            @polygons = polygons || [(1..points.length).to_a]
          end

          def point_at(index)
            @points[index - 1]
          end
        end

        class FakeFace
          attr_reader :reverse_count

          def initialize(points)
            @points = points
            @reverse_count = 0
          end

          def valid?
            true
          end

          def mesh(_flags)
            FakeMesh.new(@points)
          end

          def reverse!
            @points = @points.reverse
            @reverse_count += 1
            self
          end
        end

        class SnapshotFace
          attr_reader :normal, :persistent_id

          def initialize(points, polygons, persistent_id)
            @points = points
            @polygons = polygons
            @persistent_id = persistent_id
            @normal = Point.new(0.0, 0.0, 1.0)
          end

          def valid?
            true
          end

          def mesh(_flags)
            FakeMesh.new(@points, @polygons)
          end

          def material
            nil
          end

          def back_material
            nil
          end

          def layer
            nil
          end
        end

        class SnapshotEntities
          def initialize(faces)
            @faces = faces
          end

          def grep(klass)
            klass == SnapshotFace ? @faces : []
          end
        end

        class AxisVertex
          attr_reader :position, :persistent_id

          def initialize(position, persistent_id)
            @position = position
            @persistent_id = persistent_id
          end
        end

        class AxisEdge
          attr_reader :persistent_id
          attr_accessor :faces

          def initialize(persistent_id, faces = [])
            @persistent_id = persistent_id
            @faces = faces
          end

          def valid?
            true
          end
        end

        class AxisFace
          attr_reader :vertices, :normal, :edges

          def initialize(vertices, normal, edges = [])
            @vertices = vertices
            @normal = normal
            @edges = edges
          end

          def valid?
            true
          end
        end

        class AxisEntities
          def initialize(faces)
            @faces = faces
          end

          def grep(klass)
            klass == AxisFace ? @faces : []
          end
        end

        class FakeModel
          attr_reader :calls
          attr_accessor :start_result, :commit_result, :abort_result

          def initialize
            @calls = []
            @start_result = true
            @commit_result = true
            @abort_result = true
          end

          def start_operation(name, transparent)
            @calls << [:start_operation, name, transparent]
            @start_result
          end

          def commit_operation
            @calls << [:commit_operation]
            @commit_result
          end

          def abort_operation
            @calls << [:abort_operation]
            @abort_result
          end
        end

        def test_operation_commits_successful_reconstruction
          model = FakeModel.new
          result = normalizer(model: model).send(:with_normalization_operation, Object.new) do
            :rebuilt
          end

          assert_equal :rebuilt, result
          assert_equal :start_operation, model.calls[0][0]
          assert_equal [[:commit_operation]], model.calls.drop(1)
        end

        def test_operation_aborts_when_reconstruction_raises
          model = FakeModel.new
          error = assert_raises(RuntimeError) do
            normalizer(model: model).send(:with_normalization_operation, Object.new) do
              raise 'rebuild failed'
            end
          end

          assert_equal 'rebuild failed', error.message
          assert_equal [:start_operation, :abort_operation], model.calls.map(&:first)
        end

        def test_operation_aborts_when_commit_fails
          model = FakeModel.new
          model.commit_result = false

          assert_raises(LocalVertexNormalizer::OperationError) do
            normalizer(model: model).send(:with_normalization_operation, Object.new) { :rebuilt }
          end

          assert_equal(
            [:start_operation, :commit_operation, :abort_operation],
            model.calls.map(&:first)
          )
        end

        def test_inward_shell_is_reversed_as_a_whole
          faces = tetrahedron_faces.map do |points|
            FakeFace.new(points.reverse)
          end

          result = normalizer(face_class: FakeFace).send(:orient_shell_outward, faces)

          assert_equal 4, result[:reversed_faces]
          assert_operator result[:signed_volume_before_in3], :<, 0.0
          assert_operator result[:signed_volume_after_in3], :>, 0.0
          assert faces.all? { |face| face.reverse_count == 1 }
        end

        def test_outward_shell_is_not_reversed
          faces = tetrahedron_faces.map { |points| FakeFace.new(points) }

          result = normalizer(face_class: FakeFace).send(:orient_shell_outward, faces)

          assert_equal 0, result[:reversed_faces]
          assert_operator result[:signed_volume_before_in3], :>, 0.0
          assert_equal result[:signed_volume_before_in3], result[:signed_volume_after_in3]
          assert faces.all? { |face| face.reverse_count.zero? }
        end

        def test_zero_signed_volume_is_rejected
          faces = [FakeFace.new([point(0, 0, 0), point(1, 0, 0), point(0, 1, 0)])]

          assert_raises(LocalVertexNormalizer::TopologyChangedError) do
            normalizer(face_class: FakeFace).send(:orient_shell_outward, faces)
          end
        end

        def test_connected_axis_faces_share_one_grid_plane_before_vertex_rounding
          vertices = [
            AxisVertex.new(mm_point(0, 0, 10.0001), 1),
            AxisVertex.new(mm_point(1, 0, 10.0007), 2),
            AxisVertex.new(mm_point(0, 1, 9.9999), 3),
            AxisVertex.new(mm_point(1, 1, 10.0003), 4)
          ]
          shared_edge = AxisEdge.new(100)
          faces = [
            AxisFace.new(
              [vertices[0], vertices[1], vertices[2]],
              point(0, 0, 1),
              [shared_edge]
            ),
            AxisFace.new(
              [vertices[1], vertices[3], vertices[2]],
              point(0, 0, 1),
              [shared_edge]
            )
          ]
          instance = normalizer(face_class: AxisFace)

          plan = instance.send(:axis_plane_normalization_plan, AxisEntities.new(faces))
          target = instance.send(:normalized_target, vertices[1].position, plan)

          assert_equal 1, plan[:cluster_count]
          assert_equal 2, plan[:face_count]
          assert_equal 4, plan[:constrained_vertex_count]
          assert_equal({ 2 => 1 }, plan[:axis_cluster_counts])
          assert_in_delta 10.0, target.z * 25.4, 1.0e-9
          assert_in_delta 0.0007, plan[:max_displacement_mm], 1.0e-9
        end

        def test_edge_connected_axis_faces_are_unified_without_distance_cutoff
          vertices = [
            AxisVertex.new(mm_point(0, 0, 0.000), 1),
            AxisVertex.new(mm_point(1, 0, 0.009), 2),
            AxisVertex.new(mm_point(0, 1, 0.000), 3),
            AxisVertex.new(mm_point(1, 1, 0.018), 4),
            AxisVertex.new(mm_point(2, 0, 0.009), 5)
          ]
          shared_edge = AxisEdge.new(200)
          faces = [
            AxisFace.new(
              [vertices[0], vertices[1], vertices[2]],
              point(0, 0, 1),
              [shared_edge]
            ),
            AxisFace.new(
              [vertices[1], vertices[3], vertices[2], vertices[4]],
              point(0, 0, 1),
              [shared_edge]
            )
          ]
          instance = normalizer(face_class: AxisFace)

          plan = instance.send(:axis_plane_normalization_plan, AxisEntities.new(faces))

          assert_equal 1, plan[:cluster_count]
          assert_equal 2, plan[:face_count]
          assert_equal 5, plan[:constrained_vertex_count]
          assert_equal({ 2 => 1 }, plan[:axis_cluster_counts])
          vertices.each do |vertex|
            target = instance.send(:normalized_target, vertex.position, plan)
            assert_in_delta 0.009, target.z * 25.4, 1.0e-9
          end
          assert_in_delta 0.009, plan[:max_displacement_mm], 1.0e-9
        end

        def test_face_outside_axis_angle_tolerance_uses_ordinary_grid_projection
          vertices = [
            AxisVertex.new(mm_point(0, 0, 10.0001), 1),
            AxisVertex.new(mm_point(1, 0, 10.0007), 2),
            AxisVertex.new(mm_point(0, 1, 9.9999), 3)
          ]
          angle = 0.02 * Math::PI / 180.0
          face = AxisFace.new(
            vertices,
            point(Math.sin(angle), 0, Math.cos(angle))
          )
          instance = normalizer(face_class: AxisFace)

          plan = instance.send(:axis_plane_normalization_plan, AxisEntities.new([face]))
          target = instance.send(:normalized_target, vertices[1].position, plan)

          assert_equal 0, plan[:cluster_count]
          assert_in_delta 10.001, target.z * 25.4, 1.0e-9
        end

        def test_disconnected_parallel_faces_are_not_forced_onto_one_plane
          first_vertices = [
            AxisVertex.new(mm_point(0, 0, 10.0004), 1),
            AxisVertex.new(mm_point(1, 0, 10.0004), 2),
            AxisVertex.new(mm_point(0, 1, 10.0004), 3)
          ]
          second_vertices = [
            AxisVertex.new(mm_point(2, 0, 10.0006), 4),
            AxisVertex.new(mm_point(3, 0, 10.0006), 5),
            AxisVertex.new(mm_point(2, 1, 10.0006), 6)
          ]
          faces = [
            AxisFace.new(first_vertices, point(0, 0, 1), [AxisEdge.new(301)]),
            AxisFace.new(second_vertices, point(0, 0, 1), [AxisEdge.new(302)])
          ]
          instance = normalizer(face_class: AxisFace)

          plan = instance.send(:axis_plane_normalization_plan, AxisEntities.new(faces))
          first_target = instance.send(:normalized_target, first_vertices[0].position, plan)
          second_target = instance.send(:normalized_target, second_vertices[0].position, plan)

          assert_equal 2, plan[:cluster_count]
          assert_in_delta 10.000, first_target.z * 25.4, 1.0e-9
          assert_in_delta 10.001, second_target.z * 25.4, 1.0e-9
        end

        def test_only_shared_edges_between_faces_on_the_same_exact_axis_plane_are_mergeable
          first_vertices = [
            AxisVertex.new(mm_point(0, 0, 10), 1),
            AxisVertex.new(mm_point(1, 0, 10), 2),
            AxisVertex.new(mm_point(0, 1, 10), 3)
          ]
          second_vertices = [
            first_vertices[1],
            AxisVertex.new(mm_point(1, 1, 10), 4),
            first_vertices[2]
          ]
          ceiling_vertices = [
            AxisVertex.new(mm_point(0, 0, 20), 5),
            AxisVertex.new(mm_point(1, 0, 20), 6),
            AxisVertex.new(mm_point(0, 1, 20), 7)
          ]
          first = AxisFace.new(first_vertices, point(0, 0, 1))
          second = AxisFace.new(second_vertices, point(0, 0, 1))
          ceiling = AxisFace.new(ceiling_vertices, point(0, 0, 1))
          same_plane_edge = AxisEdge.new(401, [first, second])
          different_plane_edge = AxisEdge.new(402, [first, ceiling])
          instance = normalizer(face_class: AxisFace)

          assert instance.send(:axis_plane_merge_candidate_edge?, same_plane_edge)
          refute instance.send(:axis_plane_merge_candidate_edge?, different_plane_edge)
        end

        def test_exact_duplicate_mesh_triangles_are_canonicalized_before_manifold_validation
          points = [
            mm_point(0, 0, 0),
            mm_point(10, 0, 0),
            mm_point(0, 10, 0)
          ]
          face = SnapshotFace.new(points, [[1, 2, 3], [1, 2, 3]], 501)
          diagnostics = {}
          instance = normalizer(face_class: SnapshotFace)

          triangles = instance.send(
            :normalized_triangle_snapshot,
            SnapshotEntities.new([face]),
            duplicate_diagnostics: diagnostics
          )

          assert_equal 1, triangles.length
          assert_equal 1, diagnostics[:duplicate_count]
          assert_equal 501, diagnostics.dig(:samples, 0, :kept_face_key)
          assert_equal 501, diagnostics.dig(:samples, 0, :duplicate_face_key)
        end

        def test_canonicalized_duplicate_mesh_still_requires_a_closed_two_manifold
          faces = tetrahedron_faces.each_with_index.map do |points, index|
            polygons = index.zero? ? [[1, 2, 3], [1, 2, 3]] : [[1, 2, 3]]
            SnapshotFace.new(points, polygons, 600 + index)
          end
          diagnostics = {}
          instance = normalizer(face_class: SnapshotFace)
          triangles = instance.send(
            :normalized_triangle_snapshot,
            SnapshotEntities.new(faces),
            duplicate_diagnostics: diagnostics
          )

          validation = instance.send(:validate_normalized_triangle_mesh!, triangles)

          assert_equal 1, diagnostics[:duplicate_count]
          assert_equal 4, validation[:triangle_count]
          assert_equal 1, validation[:component_count]
        end

        def test_degenerate_mesh_fan_uses_the_short_boundary_edges_and_alternate_diagonal
          points = [
            mm_point(0, 0, 0),
            mm_point(5, 0, 0),
            mm_point(10, 0, 0),
            mm_point(0, 10, 0)
          ]
          face = SnapshotFace.new(points, [[1, 2, 3], [1, 3, 4]], 701)
          instance = normalizer(face_class: SnapshotFace)
          triangles = instance.send(
            :normalized_triangle_snapshot,
            SnapshotEntities.new([face])
          )

          repaired, report = instance.send(
            :repair_degenerate_source_triangles,
            triangles
          )
          signatures = repaired.map do |record|
            record[:points].map { |point| instance.send(:grid_indices, point) }.sort
          end
          expected = [
            [[0, 0, 0], [5_000, 0, 0], [0, 10_000, 0]].sort,
            [[5_000, 0, 0], [10_000, 0, 0], [0, 10_000, 0]].sort
          ]

          assert_equal 1, report[:repaired_triangles]
          assert_equal 1, report[:replaced_pairs]
          assert_equal expected.sort, signatures.sort
          refute repaired.any? { |record| instance.send(:degenerate_triangle_record?, record) }
        end

        def test_degenerate_repair_report_aggregates_each_mesh_stage
          instance = normalizer
          report = instance.send(
            :aggregate_degenerate_repair_reports,
            source: { repaired_triangles: 1, replaced_pairs: 1 },
            conforming: { repaired_triangles: 0, replaced_pairs: 0 },
            rebuilt: { repaired_triangles: 0, replaced_pairs: 0 },
            final: { repaired_triangles: 2, replaced_pairs: 2 }
          )

          assert_equal 3, report[:repaired_triangles]
          assert_equal 3, report[:replaced_pairs]
          assert_equal 2, report.dig(:stages, :final, :repaired_triangles)
        end

        private

        def normalizer(model: nil, face_class: FakeFace)
          LocalVertexNormalizer.new(
            0.001,
            point_factory: ->(x, y, z) { Point.new(x, y, z) },
            vector_factory: ->(x, y, z) { [x, y, z] },
            edge_class: Sketchup::Edge,
            face_class: face_class,
            model: model
          )
        end

        def tetrahedron_faces
          origin = point(0, 0, 0)
          x = point(1, 0, 0)
          y = point(0, 1, 0)
          z = point(0, 0, 1)
          [
            [origin, y, x],
            [origin, x, z],
            [origin, z, y],
            [x, y, z]
          ]
        end

        def point(x, y, z)
          Point.new(x.to_f, y.to_f, z.to_f)
        end

        def mm_point(x, y, z)
          point(x.to_f / 25.4, y.to_f / 25.4, z.to_f / 25.4)
        end
      end
    end
  end
end
