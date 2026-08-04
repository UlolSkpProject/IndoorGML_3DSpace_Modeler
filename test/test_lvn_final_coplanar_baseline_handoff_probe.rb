# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/lvn_final_coplanar_baseline_handoff_probe'

class LvnFinalCoplanarBaselineHandoffProbeTest < Minitest::Test
  Point = Struct.new(:x, :y, :z)
  Definition = Struct.new(:entities)
  Entity = Struct.new(:definition)

  def setup
    @material = Object.new
    @back_material = Object.new
    @layer = Object.new
    @other_material = Object.new
    @point_key_builder = ->(point) { [point.x, point.y, point.z] }
    @metadata_identity_builder = lambda do |value|
      value.nil? ? nil : [:object_id, value.object_id]
    end
  end

  def test_inventory_ignores_record_order_and_cyclic_triangle_rotation
    records = [
      record(
        [point(0, 0, 0), point(10, 0, 0), point(0, 10, 0)]
      ),
      record(
        [point(0, 0, 10), point(0, 10, 10), point(10, 0, 10)]
      )
    ]
    reordered = [
      record(
        [point(0, 10, 10), point(10, 0, 10), point(0, 0, 10)]
      ),
      record(
        [point(10, 0, 0), point(0, 10, 0), point(0, 0, 0)]
      )
    ]

    assert_equal inventory(records), inventory(reordered)
  end

  def test_comparison_detects_reversed_winding_without_losing_geometry_match
    original = inventory([
      record([point(0, 0, 0), point(10, 0, 0), point(0, 10, 0)])
    ])
    reversed = inventory([
      record([point(0, 0, 0), point(0, 10, 0), point(10, 0, 0)])
    ])

    comparison = compare(original, reversed)

    assert comparison[:canonical_triangle_set_match]
    refute comparison[:orientation_match]
    refute comparison[:fully_equivalent]
    assert comparison[:mismatch_samples].key?(:oriented_triangles)
  end

  def test_comparison_detects_metadata_mismatch
    original = inventory([
      record([point(0, 0, 0), point(10, 0, 0), point(0, 10, 0)])
    ])
    changed = inventory([
      record(
        [point(0, 0, 0), point(10, 0, 0), point(0, 10, 0)],
        material: @other_material
      )
    ])

    comparison = compare(original, changed)

    assert comparison[:canonical_triangle_set_match]
    assert comparison[:orientation_match]
    refute comparison[:metadata_match]
    refute comparison[:fully_equivalent]
  end

  def test_comparison_accepts_complete_handoff_equivalence
    candidate_inventory = inventory([
      record([point(0, 0, 0), point(10, 0, 0), point(0, 10, 0)])
    ])
    baseline_inventory = inventory([
      record([point(10, 0, 0), point(0, 10, 0), point(0, 0, 0)])
    ])

    comparison = compare(candidate_inventory, baseline_inventory)

    assert comparison[:triangle_count_match]
    assert comparison[:canonical_triangle_set_match]
    assert comparison[:orientation_match]
    assert comparison[:source_normal_match]
    assert comparison[:metadata_match]
    assert comparison[:topology_match]
    assert comparison[:grid_residual_match]
    assert comparison[:fully_equivalent]
  end

  def test_extension_captures_and_attaches_full_pipeline_comparison
    records = [
      record([point(0, 0, 0), point(10, 0, 0), point(0, 10, 0)])
    ]
    normalizer_class = full_pipeline_normalizer_class

    normalizer = normalizer_class.new(records)
    result = normalizer.send(
      :normalize_entity,
      Entity.new(Definition.new(Object.new))
    )
    profile = normalizer.local_vertex_normalizer_debug_profile
    probe = profile.fetch(
      LvnFinalCoplanarBaselineHandoffProbe::PROFILE_KEY
    )

    assert_equal({ ok: true }, result)
    assert probe[:candidate_available]
    assert_equal :final_fallback, probe[:candidate_role]
    assert probe[:baseline_available]
    assert probe[:fully_equivalent]
    assert_equal 1, probe[:comparison_count]
    assert probe[:existing_baseline_was_not_bypassed]
  end

  def test_extension_captures_normalized_input_fast_path_candidate
    records = [
      record([point(0, 0, 0), point(10, 0, 0), point(0, 10, 0)])
    ]
    normalizer_class = fast_path_normalizer_class

    normalizer = normalizer_class.new(records)
    result = normalizer.send(
      :normalize_entity,
      Entity.new(Definition.new(Object.new))
    )
    profile = normalizer.local_vertex_normalizer_debug_profile
    probe = profile.fetch(
      LvnFinalCoplanarBaselineHandoffProbe::PROFILE_KEY
    )

    assert_equal({ ok: true }, result)
    assert probe[:candidate_available]
    assert_equal :normalized_input_fast_path, probe[:candidate_role]
    assert probe[:baseline_available]
    assert probe[:fully_equivalent]
    assert_nil probe[:candidate_capture_error]
  end

  def test_aggregate_counts_only_equivalent_baseline_time_as_removable
    samples = [
      {
        pid: 101,
        label: 'ok',
        final_coplanar_baseline_handoff_probe: {
          candidate_available: true,
          candidate_role: :post_coplanar_cleanup,
          baseline_available: true,
          fully_equivalent: true,
          baseline_snapshot_seconds: 2.5,
          candidate_capture_seconds: 0.1,
          comparison_seconds: 0.2,
          mismatch_samples: {},
          candidate_capture_error: nil
        }
      },
      {
        pid: 202,
        label: 'mismatch',
        final_coplanar_baseline_handoff_probe: {
          candidate_available: true,
          candidate_role: :normalized_input_fast_path,
          baseline_available: true,
          fully_equivalent: false,
          baseline_snapshot_seconds: 3.5,
          candidate_capture_seconds: 0.2,
          comparison_seconds: 0.3,
          mismatch_samples: { metadata: {} },
          candidate_capture_error: nil
        }
      }
    ]

    aggregate =
      LvnFinalCoplanarBaselineHandoffProbe.aggregate_summaries(samples)

    assert_equal 2, aggregate[:profiled_entity_count]
    assert_equal 2, aggregate[:candidate_available_count]
    assert_equal 1, aggregate[:fully_equivalent_count]
    assert_equal [202], aggregate[:mismatch_pids]
    assert_in_delta 6.0, aggregate[:baseline_snapshot_seconds], 1.0e-12
    assert_in_delta 2.5,
                    aggregate[:removable_baseline_snapshot_seconds],
                    1.0e-12
    refute aggregate[:all_equivalent]
  end

  def test_install_is_idempotent
    klass = Class.new

    assert LvnFinalCoplanarBaselineHandoffProbe.install!(klass)
    refute LvnFinalCoplanarBaselineHandoffProbe.install!(klass)
    count = klass.ancestors.count do |ancestor|
      ancestor.equal?(
        LvnFinalCoplanarBaselineHandoffProbe::Extensions
      )
    end
    assert_equal 1, count
  end

  private

  def point(x, y, z)
    Point.new(x, y, z)
  end

  def record(points, material: @material)
    {
      points: points,
      source_normal: [0.0, 0.0, 1.0],
      material: material,
      back_material: @back_material,
      layer: @layer
    }
  end

  def inventory(records)
    LvnFinalCoplanarBaselineHandoffProbe.build_inventory(
      records,
      point_key_builder: @point_key_builder,
      metadata_identity_builder: @metadata_identity_builder
    )
  end

  def compare(candidate_inventory, baseline_inventory)
    topology = topology_fixture
    LvnFinalCoplanarBaselineHandoffProbe.compare(
      {
        available: true,
        role: :post_coplanar_cleanup,
        inventory: candidate_inventory,
        topology: topology,
        grid_residual_mm: 0.0
      },
      baseline_inventory: baseline_inventory,
      baseline_topology: topology.dup,
      baseline_grid_residual_mm: 0.0,
      baseline_snapshot_seconds: 1.25
    )
  end

  def topology_fixture
    {
      faces: 4,
      edges: 6,
      vertices: 4,
      boundary_edges: 0,
      wire_edges: 0,
      overused_edges: 0,
      orientation_conflicts: 0
    }
  end

  def install_fake_geometry_methods(klass)
    topology = topology_fixture
    klass.class_eval do
      attr_reader :local_vertex_normalizer_debug_profile

      define_method(:initialize) do |triangle_records|
        @triangle_records = triangle_records
        @local_vertex_normalizer_debug_profile = {}
      end

      private

      define_method(:snapshot_final_coplanar_baseline) do |_entities|
        @triangle_records
      end

      define_method(:max_grid_residual_mm) do |_vertices|
        0.0
      end

      define_method(:geometry_vertices) do |_entities|
        []
      end

      define_method(:geometry_counts) do |_entities|
        topology.dup
      end

      define_method(:grid_indices) do |point_value|
        [point_value.x, point_value.y, point_value.z]
      end

      define_method(:metadata_identity) do |value|
        value.nil? ? nil : [:object_id, value.object_id]
      end
    end
    klass
  end

  def full_pipeline_normalizer_class
    klass = Class.new
    install_fake_geometry_methods(klass)
    klass.class_eval do
      private

      define_method(:normalize_entity) do |entity|
        max_grid_residual_mm([])
        final_normalized_mesh_state(
          entity.definition.entities,
          @triangle_records,
          { attempted: false },
          geometry_counts(entity.definition.entities),
          nil,
          {}
        )
        snapshot_final_coplanar_baseline(entity.definition.entities)
        { ok: true }
      end

      define_method(:final_normalized_mesh_state) do |*arguments|
        [
          @triangle_records,
          {},
          { triangle_count: @triangle_records.length },
          { equivalent: true },
          { reused: false }
        ]
      end
    end
    klass.prepend(LvnFinalCoplanarBaselineHandoffProbe::Extensions)
    klass
  end

  def fast_path_normalizer_class
    klass = Class.new
    install_fake_geometry_methods(klass)
    klass.class_eval do
      private

      define_method(:normalize_entity) do |entity|
        entities = entity.definition.entities
        max_grid_residual_mm([])
        @normalized_input_fast_path_baseline_v2 = {
          entities_object_id: entities.object_id,
          topology: geometry_counts(entities),
          triangles: @triangle_records
        }
        snapshot_final_coplanar_baseline(entities)
        { ok: true }
      end
    end
    klass.prepend(LvnFinalCoplanarBaselineHandoffProbe::Extensions)
    klass
  end
end
