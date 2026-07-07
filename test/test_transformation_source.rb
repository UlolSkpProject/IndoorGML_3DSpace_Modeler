# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      class TransformationSourceTest < Minitest::Test
        def test_active_context_transform_uses_world_transform_helper
          source = File.read(File.expand_path('../indoor3d/utils/transformation.rb', __dir__))
          method_body = source[/def self\.entity_transformation_in_active_context\(entity\).*?^\s*end/m]

          assert_includes method_body, 'entity_world_transformation(entity)'
          refute_includes method_body, 'edit_transform * entity.transformation'
        end
      end
    end
  end
end
