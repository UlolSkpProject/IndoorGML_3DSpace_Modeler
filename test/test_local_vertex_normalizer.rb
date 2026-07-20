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

        SliverVertex = Struct.new(:position)

        class SliverEdge
          attr_reader :vertices
          attr_accessor :faces

          def initialize(vertex_a, vertex_b)
            @vertices = [vertex_a, vertex_b]
            @faces = []
          end

          def valid?
            true
          end
        end

        SliverLoop = Struct.new(:vertices, :edges)
        SupportFace = Struct.new(:persistent_id)

        class SliverFace
          attr_reader :outer_loop, :persistent_id

          def initialize(outer_loop, persistent_id)
            @outer_loop = outer_loop
            @persistent_id = persistent_id
          end

          def valid?
            true
          end

          def loops
            [@outer_loop]
          end
        end

        class SliverEntities
          def initialize(faces, edges)
            @faces = faces
            @edges = edges
          end

          def grep(klass)
            return @faces if klass == SliverFace
            return @edges if klass == SliverEdge

            []
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

        def test_short_edge_sliver_shape_requires_opposite_short_edges
          instance = normalizer
          sliver = [
            mm_point(0, 0, 0),
            mm_point(0.2, 0, 0),
            mm_point(0.2, 0, 100),
            mm_point(0, 0, 100)
          ]
          isolated_short_crease = [
            mm_point(0, 0, 0),
            mm_point(0.2, 0, 0),
            mm_point(10, 10, 0),
            mm_point(0, 10, 0)
          ]

          shape = instance.send(:short_edge_sliver_quad_shape, sliver)

          refute_nil shape
          assert_equal 2, shape[:short_edge_pairs].length
          assert_operator shape[:aspect_ratio], :>, 400.0
          assert_nil instance.send(
            :short_edge_sliver_quad_shape,
            isolated_short_crease
          )
        end

        def test_short_edge_sliver_collapse_preserves_closed_shell_euler_characteristic
          instance = normalizer
          triangles, points = sliver_prism_triangle_records
          baseline = instance.send(:validate_normalized_triangle_mesh!, triangles)
          bottom_a = points.fetch(:bottom_a)
          bottom_b = points.fetch(:bottom_b)
          top_a = points.fetch(:top_a)
          top_b = points.fetch(:top_b)
          plan = {
            repairable: true,
            detected_face_count: 2,
            repairable_patch_count: 1,
            repaired_face_count: 2,
            point_targets: {
              instance.send(:grid_indices, bottom_b) => bottom_a,
              instance.send(:grid_indices, top_b) => top_a
            },
            collapsed_clusters: [],
            collapsed_cluster_count: 2,
            collapsed_vertex_count: 2,
            max_displacement_mm: 0.2,
            skipped_patches: [],
            candidates: []
          }

          repaired, report = instance.send(
            :collapse_short_edge_sliver_triangles,
            triangles,
            plan,
            baseline
          )
          validation = instance.send(:validate_normalized_triangle_mesh!, repaired)
          instance.send(
            :validate_short_edge_sliver_topology!,
            baseline,
            validation,
            report
          )

          assert_equal 2, instance.send(:triangle_mesh_euler_characteristic, baseline)
          assert_equal 2, instance.send(:triangle_mesh_euler_characteristic, validation)
          assert_equal 4, report[:removed_degenerate_triangle_count]
          assert_equal 0, report[:removed_duplicate_triangle_count]
          assert_equal 10, baseline[:vertex_count]
          assert_equal 8, validation[:vertex_count]
          assert_equal 1, validation[:component_count]
        end

        def test_short_edge_cluster_wider_than_one_millimetre_is_not_collapsed
          instance = normalizer
          points = [
            mm_point(0, 0, 0),
            mm_point(0.6, 0, 0),
            mm_point(1.2, 0, 0)
          ]
          point_by_key = points.each_with_object({}) do |point, result|
            result[instance.send(:grid_indices, point)] = point
          end
          keys = points.map { |point| instance.send(:grid_indices, point) }

          result = instance.send(
            :short_edge_cluster_targets,
            [[keys[0], keys[1]], [keys[1], keys[2]]],
            point_by_key
          )

          refute result[:ok]
          assert_equal :cluster_too_wide, result[:reason]
        end

        def test_only_repeated_sliver_faces_between_the_same_support_faces_are_repairable
          support_top = SupportFace.new(10_001)
          support_bottom = SupportFace.new(10_002)
          first_face, first_edges = sliver_face(
            x_mm: 0,
            persistent_id: 20_001,
            support_top: support_top,
            support_bottom: support_bottom
          )
          second_face, second_edges = sliver_face(
            x_mm: 10,
            persistent_id: 20_002,
            support_top: support_top,
            support_bottom: support_bottom
          )
          instance = normalizer(
            face_class: SliverFace,
            edge_class: SliverEdge
          )

          isolated = instance.send(
            :short_edge_sliver_collapse_plan,
            SliverEntities.new([first_face], first_edges)
          )
          repeated = instance.send(
            :short_edge_sliver_collapse_plan,
            SliverEntities.new(
              [first_face, second_face],
              first_edges + second_edges
            )
          )

          assert_equal 1, isolated[:detected_face_count]
          refute isolated[:repairable]
          assert_equal 2, repeated[:detected_face_count]
          assert repeated[:repairable]
          assert_equal 1, repeated[:repairable_patch_count]
          assert_equal 4, repeated[:collapsed_cluster_count]
          assert_equal 4, repeated[:collapsed_vertex_count]
        end

        def test_crash_ring_style_short_edges_form_one_repairable_patch
          support_top = SupportFace.new(30_001)
          support_bottom = SupportFace.new(30_002)
          widths_mm = [
            0.210341482,
            0.056224511,
            0.210341482,
            0.154205206,
            0.210341482,
            0.210341482,
            0.210341482,
            0.210341482,
            0.154205206,
            0.056224511
          ]
          faces = []
          edges = []
          widths_mm.each_with_index do |width_mm, index|
            face, face_edges = sliver_face(
              x_mm: index * 10,
              width_mm: width_mm,
              height_mm: 4_800,
              persistent_id: 31_000 + index,
              support_top: support_top,
              support_bottom: support_bottom
            )
            faces << face
            edges.concat(face_edges)
          end
          instance = normalizer(
            face_class: SliverFace,
            edge_class: SliverEdge
          )

          plan = instance.send(
            :short_edge_sliver_collapse_plan,
            SliverEntities.new(faces, edges)
          )

          assert plan[:repairable]
          assert_equal 10, plan[:detected_face_count]
          assert_equal 1, plan[:repairable_patch_count]
          assert_equal 20, plan[:collapsed_cluster_count]
          assert_equal 20, plan[:collapsed_vertex_count]
          assert_operator plan[:max_displacement_mm], :<, 0.106
        end

        private

        def normalizer(model: nil, face_class: FakeFace, edge_class: Sketchup::Edge)
          LocalVertexNormalizer.new(
            0.001,
            point_factory: ->(x, y, z) { Point.new(x, y, z) },
            vector_factory: ->(x, y, z) { [x, y, z] },
            edge_class: edge_class,
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

        def sliver_prism_triangle_records
          bottom = [
            mm_point(0, 0, 0),
            mm_point(0.2, 0, 0),
            mm_point(10, 0, 0),
            mm_point(10, 10, 0),
            mm_point(0, 10, 0)
          ]
          top = bottom.map { |point| mm_point(point.x * 25.4, point.y * 25.4, 10) }
          triangles = []
          add_triangle_record(triangles, bottom[3], bottom[4], bottom[0], :bottom)
          add_triangle_record(triangles, bottom[3], bottom[0], bottom[1], :bottom)
          add_triangle_record(triangles, bottom[3], bottom[1], bottom[2], :bottom)
          add_triangle_record(triangles, top[3], top[0], top[4], :top)
          add_triangle_record(triangles, top[3], top[1], top[0], :top)
          add_triangle_record(triangles, top[3], top[2], top[1], :top)

          5.times do |index|
            following = (index + 1) % 5
            add_triangle_record(
              triangles,
              bottom[index],
              bottom[following],
              top[following],
              "side_#{index}".to_sym
            )
            add_triangle_record(
              triangles,
              bottom[index],
              top[following],
              top[index],
              "side_#{index}".to_sym
            )
          end

          [
            triangles,
            {
              bottom_a: bottom[0],
              bottom_b: bottom[1],
              top_a: top[0],
              top_b: top[1]
            }
          ]
        end

        def add_triangle_record(records, point_a, point_b, point_c, source_face_key)
          records << {
            points: [point_a, point_b, point_c],
            source_normal: [0.0, 0.0, 1.0],
            material: nil,
            back_material: nil,
            layer: nil,
            source_face_key: source_face_key,
            source_polygon_index: records.length
          }
        end

        def sliver_face(
          x_mm:,
          persistent_id:,
          support_top:,
          support_bottom:,
          width_mm: 0.2,
          height_mm: 100
        )
          vertices = [
            SliverVertex.new(mm_point(x_mm, 0, 0)),
            SliverVertex.new(mm_point(x_mm + width_mm, 0, 0)),
            SliverVertex.new(mm_point(x_mm + width_mm, 0, height_mm)),
            SliverVertex.new(mm_point(x_mm, 0, height_mm))
          ]
          edges = 4.times.map do |index|
            SliverEdge.new(vertices[index], vertices[(index + 1) % 4])
          end
          face = SliverFace.new(SliverLoop.new(vertices, edges), persistent_id)
          edges.each { |edge| edge.faces = [face] }
          edges[0].faces << support_top
          edges[2].faces << support_bottom
          [face, edges]
        end
      end
    end
  end
end
