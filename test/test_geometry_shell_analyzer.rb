# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/utils/geometry'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      class GeometryShellAnalyzerTest < Minitest::Test
        FakeDefinition = Struct.new(:bounds)
        FakeEntity = Struct.new(:definition)
        FakeBounds = Struct.new(:center)

        def test_adaptive_inner_sample_retries_with_finer_grids
          attempted_divisions = []
          finder = proc do |_faces, _bounds, divisions, _tolerance, fixed_z: nil|
            attempted_divisions << [divisions, fixed_z]
            divisions == 12 ? [:inside, 3.5] : [nil, nil]
          end

          result = with_stubbed_singleton_method(Geometry, :best_inner_sample, finder) do
            Geometry.send(:adaptive_inner_sample, [:face], :bounds, 0.001, fixed_z: 10.0)
          end

          assert_equal [:inside, 3.5, 12], result
          assert_equal [[8, 10.0], [12, 10.0]], attempted_divisions
        end

          def test_inner_centroid_does_not_fall_back_to_unverified_bounds_center
          center = Object.new
          entity = FakeEntity.new(FakeDefinition.new(FakeBounds.new(center)))

          with_stubbed_singleton_method(Geometry, :local_shell_faces, proc { |_entity| [:face] }) do
            with_stubbed_singleton_method(Geometry, :shell_contains_point?, proc { |_faces, _point, _tolerance| false }) do
              with_stubbed_singleton_method(Geometry, :adaptive_inner_sample, proc { |_faces, _bounds, _tolerance, fixed_z: nil| [nil, nil, nil] }) do
                with_stubbed_singleton_method(Geometry, :face_inset_inner_sample, proc { |_faces, _bounds, _tolerance, fixed_z: nil| [nil, nil] }) do
                  assert_raises(ArgumentError) { Geometry.find_shell_inner_centroid(entity) }
                end
              end
            end
          end

          def test_inner_centroid_uses_verified_face_inset_when_axis_grid_misses
            center = Object.new
            bounds = FakeBounds.new(center)
            entity = FakeEntity.new(FakeDefinition.new(bounds))
            inset_point = Object.new

            with_stubbed_singleton_method(Geometry, :local_shell_faces, proc { |_entity| [:face] }) do
              with_stubbed_singleton_method(Geometry, :shell_contains_point?, proc { |_faces, point, _tolerance| point == inset_point }) do
                with_stubbed_singleton_method(Geometry, :adaptive_inner_sample, proc { |_faces, _bounds, _tolerance, fixed_z: nil| [nil, nil, nil] }) do
                  with_stubbed_singleton_method(Geometry, :face_inset_inner_sample, proc { |_faces, _bounds, _tolerance, fixed_z: nil| [inset_point, 0.5] }) do
                    assert_same inset_point, Geometry.find_shell_inner_centroid(entity)
                  end
                end
              end
            end
          end
        end

        def test_shell_contains_point_stops_after_two_inside_votes
          calls = []
          directions = [:ray0, :ray1, :ray2]
          counter = proc do |_faces, _point, direction, _tolerance, ray_index: nil|
            calls << [direction, ray_index]
            1
          end

          result = with_stubbed_singleton_method(Geometry, :shell_ray_directions, proc { directions }) do
            with_stubbed_singleton_method(Geometry, :ray_intersection_count, counter) do
              Geometry.send(:shell_contains_point?, [:face], :point, 0.001)
            end
          end

          assert result
          assert_equal [[:ray0, 0], [:ray1, 1]], calls
        end

        def test_shell_contains_point_stops_after_two_outside_votes
          calls = []
          directions = [:ray0, :ray1, :ray2]
          counter = proc do |_faces, _point, direction, _tolerance, ray_index: nil|
            calls << [direction, ray_index]
            0
          end

          result = with_stubbed_singleton_method(Geometry, :shell_ray_directions, proc { directions }) do
            with_stubbed_singleton_method(Geometry, :ray_intersection_count, counter) do
              Geometry.send(:shell_contains_point?, [:face], :point, 0.001)
            end
          end

          refute result
          assert_equal [[:ray0, 0], [:ray1, 1]], calls
        end

        def test_shell_contains_point_uses_third_vote_when_first_two_split
          calls = []
          directions = [:ray0, :ray1, :ray2]
          counts = [1, 0, 1]
          counter = proc do |_faces, _point, direction, _tolerance, ray_index: nil|
            calls << [direction, ray_index]
            counts.fetch(ray_index)
          end

          result = with_stubbed_singleton_method(Geometry, :shell_ray_directions, proc { directions }) do
            with_stubbed_singleton_method(Geometry, :ray_intersection_count, counter) do
              Geometry.send(:shell_contains_point?, [:face], :point, 0.001)
            end
          end

          assert result
          assert_equal [[:ray0, 0], [:ray1, 1], [:ray2, 2]], calls
        end

        def test_unique_sorted_distances_handles_empty_and_single_values
          assert_equal [], Geometry.send(:unique_sorted_distances, [], 0.001)
          assert_equal [3.0], Geometry.send(:unique_sorted_distances, [3.0], 0.001)
        end

        def test_unique_sorted_distances_preserves_tolerance_semantics
          distances = [5.0, 1.0008, 3.0, 1.0, 3.0011]

          result = Geometry.send(:unique_sorted_distances, distances, 0.001)

          assert_equal [1.0, 3.0, 3.0011, 5.0], result
        end

        def test_unique_sorted_distances_keeps_value_exactly_at_tolerance_collapsed
          result = Geometry.send(:unique_sorted_distances, [1.0, 1.001], 0.001)

          assert_equal [1.0], result
        end

        private

        def with_stubbed_singleton_method(target, method_name, replacement)
          singleton_class = target.singleton_class
          original_name = :"__geometry_shell_analyzer_test_#{method_name}"
          was_private = singleton_class.private_method_defined?(method_name)
          singleton_class.send(:alias_method, original_name, method_name)
          singleton_class.send(:define_method, method_name, &replacement)
          yield
        ensure
          singleton_class.send(:remove_method, method_name)
          singleton_class.send(:alias_method, method_name, original_name)
          singleton_class.send(:remove_method, original_name)
          singleton_class.send(:private, method_name) if was_private
        end
      end
    end
  end
end
