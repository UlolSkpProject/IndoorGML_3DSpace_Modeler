# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerTest
        OBSOLETE_SOURCE_SLIVER_TESTS = %i[
          test_source_altitude_sliver_collapse_moves_shared_apex_to_longest_edge
          test_source_altitude_sliver_collapse_leaves_face_collapsed_to_edge
          test_source_altitude_sliver_collapse_respects_half_millimeter_threshold
          test_source_altitude_sliver_collapse_post_conforming_splits_target_edge
        ].freeze unless const_defined?(:OBSOLETE_SOURCE_SLIVER_TESTS, false)

        OBSOLETE_SOURCE_SLIVER_TESTS.each do |name|
          remove_method(name) if instance_methods(false).include?(name)
        end

        def test_source_low_altitude_triangle_is_diagnostic_only_and_keeps_shared_apex
          apex = mm_point(0, 0.1, 0)
          edge_start = mm_point(-5, 0, 0)
          edge_end = mm_point(5, 0, 0)
          upper = mm_point(0, 0, 5)
          lower = mm_point(0, 0, -5)
          records = []
          add_triangle_record(records, apex, edge_start, edge_end, 801)
          add_triangle_record(records, apex, upper, edge_start, 802)
          add_triangle_record(records, apex, edge_end, lower, 803)
          instance = normalizer

          cleaned, report = instance.send(
            :collapse_source_altitude_sliver_triangles,
            records
          )
          target_key = instance.send(:source_precision_indices, mm_point(0, 0, 0))
          apex_key = instance.send(:source_precision_indices, apex)
          output_keys = cleaned.flat_map do |record|
            record[:points].map do |point|
              instance.send(:source_precision_indices, point)
            end
          end

          assert_equal 3, cleaned.length
          assert_equal 1, report[:detected_sliver_count]
          assert_equal 0, report[:selected_apex_count]
          assert_equal 0, report[:moved_vertex_count]
          assert_equal 0, report[:moved_triangle_count]
          assert_equal 0, report[:removed_collapsed_triangle_count]
          assert_equal 1, report[:remaining_sliver_count]
          assert_includes output_keys, apex_key
          refute_includes output_keys, target_key
          assert_empty report[:affected_source_face_keys]
          assert report[:skipped]
        end

        def test_source_low_altitude_triangles_are_not_forced_to_collapse
          apex = mm_point(0, 0.1, 0)
          edge_start = mm_point(-5, 0, 0)
          edge_end = mm_point(5, 0, 0)
          foot = mm_point(0, 0, 0)
          records = []
          add_triangle_record(records, apex, edge_start, edge_end, 811)
          add_triangle_record(records, apex, edge_start, foot, 812)
          instance = normalizer

          cleaned, report = instance.send(
            :collapse_source_altitude_sliver_triangles,
            records
          )

          assert_equal 2, cleaned.length
          assert_equal 2, report[:detected_sliver_count]
          assert_equal 0, report[:removed_collapsed_triangle_count]
          assert_equal 2, report[:remaining_sliver_count]
          assert_equal 0, report[:moved_vertex_count]
          assert report[:skipped]
        end

        def test_source_low_altitude_diagnostic_threshold_is_half_millimeter
          apex = mm_point(0, 0.5001, 0)
          edge_start = mm_point(-5, 0, 0)
          edge_end = mm_point(5, 0, 0)
          records = []
          add_triangle_record(records, apex, edge_start, edge_end, 821)
          instance = normalizer

          cleaned, report = instance.send(
            :collapse_source_altitude_sliver_triangles,
            records
          )

          assert_equal records, cleaned
          refute_same records, cleaned
          assert_equal 0, report[:detected_sliver_count]
          assert_equal 1, report[:input_triangle_count]
          assert_equal 1, report[:output_triangle_count]
          assert report[:skipped]
        end

        def test_source_low_altitude_diagnostic_does_not_inject_projection_point_into_neighbor
          apex = mm_point(0, 0.1, 0)
          edge_start = mm_point(-5, 0, 0)
          edge_end = mm_point(5, 0, 0)
          upper = mm_point(0, 0, 5)
          lower = mm_point(0, 0, -5)
          opposite = mm_point(0, -5, 0)
          records = []
          add_triangle_record(records, apex, edge_start, edge_end, 831)
          add_triangle_record(records, apex, upper, edge_start, 832)
          add_triangle_record(records, apex, edge_end, lower, 833)
          add_triangle_record(records, edge_start, opposite, edge_end, 834)
          instance = normalizer

          cleaned, = instance.send(
            :collapse_source_altitude_sliver_triangles,
            records
          )
          conforming = instance.send(
            :conforming_triangle_snapshot,
            cleaned,
            coordinate_space: :source
          )
          target_key = instance.send(:source_precision_indices, mm_point(0, 0, 0))
          neighbor = conforming.select do |record|
            record[:source_face_key] == 834
          end

          assert_equal 1, neighbor.length
          refute neighbor.first[:points].any? do |point|
            instance.send(:source_precision_indices, point) == target_key
          end
        end
      end
    end
  end
end
