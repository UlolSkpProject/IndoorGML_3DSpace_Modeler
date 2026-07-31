# frozen_string_literal: true

require 'minitest/autorun'

class LvnExplicitExecutionPolicyTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  IMPLICIT_RUNTIME_PATHS = %w[
    indoor3d/application/indoor_model/local_grid_coordinate_v2.rb
    indoor3d/application/indoor_model/local_grid_runtime_dispatch_v2.rb
    indoor3d/application/indoor_model/local_grid_geometry_close_v2.rb
  ].freeze

  def test_local_grid_runtime_paths_do_not_invoke_lvn
    IMPLICIT_RUNTIME_PATHS.each do |relative_path|
      source = File.read(File.join(ROOT, relative_path))

      refute_match(/LocalVertexNormalizer\.(?:normalize|normalized\?)/, source, relative_path)
      refute_includes source, 'normalize_cell_space_local_grid_v2!', relative_path
    end
  end

  def test_explicit_indoor_model_lvn_entrypoint_remains_available
    source = File.read(
      File.join(
        ROOT,
        'indoor3d/application/indoor_model/local_vertex_normalization.rb'
      )
    )

    assert_includes source, 'def local_vertex_normalize('
    assert_includes source, 'LocalVertexNormalizer.normalize('
  end
end
