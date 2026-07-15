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
                assert_raises(ArgumentError) { Geometry.find_shell_inner_centroid(entity) }
              end
            end
          end
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
