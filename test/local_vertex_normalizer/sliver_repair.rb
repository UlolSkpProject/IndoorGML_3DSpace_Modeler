# frozen_string_literal: true

require_relative '../support/local_vertex_normalizer_test_support'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerTest < Minitest::Test
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
      end
    end
  end
end
