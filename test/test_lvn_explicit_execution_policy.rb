# frozen_string_literal: true

require 'minitest/autorun'

class LvnExplicitExecutionPolicyTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  IMPLICIT_RUNTIME_PATHS = %w[
    indoor3d/application/indoor_model/local_grid_coordinate.rb
    indoor3d/application/indoor_model/local_grid_runtime_dispatch.rb
    indoor3d/application/indoor_model/local_grid_geometry_close.rb
  ].freeze

  def test_local_grid_runtime_paths_do_not_invoke_lvn
    IMPLICIT_RUNTIME_PATHS.each do |relative_path|
      source = File.read(File.join(ROOT, relative_path))

      refute_match(/LocalVertexNormalizer\.(?:normalize|normalized\?)/, source, relative_path)
      refute_includes source, 'normalize_cell_space_local_grid!', relative_path
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

  def test_context_menu_vertex_normalize_targets_exactly_one_cell_space
    command_source = File.read(
      File.join(ROOT, 'indoor3d/ui/commands/cell_space_commands.rb')
    )
    menu_source = File.read(
      File.join(ROOT, 'indoor3d/ui/commands/display_commands.rb')
    )

    assert_includes command_source, 'return nil unless entities.length == 1'
    assert_includes command_source, 'indoor_model.local_vertex_normalize(cell_spaces: [cell_space])'
    assert_includes command_source, 'SketchupOverlayProgressRenderer.new(model: model)'
    assert_includes menu_source, "menu.add_submenu('IndoorGML 3D Modeler')"
    assert_includes menu_source, "indoor_menu.add_item('Vertex Normalize')"
  end

  def test_lvn_diagnostic_stages_feed_the_active_progress_tracker_without_enabling_reports
    source = File.read(
      File.join(
        ROOT,
        'indoor3d/application/local_vertex_normalizer/diagnostic_profiler.rb'
      )
    )

    assert_includes source, 'notify_local_vertex_normalizer_progress(stage, details)'
    assert_match(
      /notify_local_vertex_normalizer_progress\(stage, details\).*?profile =/m,
      source
    )
  end

  def test_lvn_does_not_own_adjacency_or_transition_synchronization
    lvn_paths = %w[
      indoor3d/application/indoor_model/local_vertex_normalization.rb
      indoor3d/application/precision_validation/lvn_integration.rb
    ]

    lvn_paths.each do |relative_path|
      source = File.read(File.join(ROOT, relative_path))

      refute_includes source, 'topology_coordinator.synchronize_all', relative_path
      refute_includes source, 'invalidate_overlay_transition_points', relative_path
      refute_includes source, 'IndoorGML LVN Topology Synchronize', relative_path
    end
  end
end
