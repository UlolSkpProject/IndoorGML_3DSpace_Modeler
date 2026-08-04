# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/lvn_source_boundary_validation_reuse_probe'

class LvnSourceBoundaryValidationReuseProbeTest < Minitest::Test
  Point = Struct.new(:x, :y, :z)

  class FakeNormalizer
    attr_reader :profile

    def initialize
      @local_vertex_normalizer_debug_profile = {}
      @profile = @local_vertex_normalizer_debug_profile
      @outcomes = []
    end

    def queue_outcomes(*outcomes)
      @outcomes.concat(outcomes)
    end

    def run_normalize(&block)
      send(:normalize_entity, block)
    end

    def run_validation(records, loops, triangle_keys: nil)
      send(
        :validate_source_boundary_retriangulation!,
        records,
        loops,
        triangle_keys: triangle_keys
      )
    end

    private

    def normalize_entity(callback)
      callback.call(self)
      :normalized
    end

    def validate_source_boundary_retriangulation!(
      _records,
      _loops,
      triangle_keys: nil
    )
      outcome = @outcomes.shift || :success
      raise RuntimeError, outcome.to_s unless outcome == :success

      triangle_keys.nil? ? :records : :keys
    end

    def source_precision_indices(point)
      [point.x, point.y, point.z]
    end
  end

  LvnSourceBoundaryValidationReuseProbe.install!(FakeNormalizer)

  def setup
    @triangles = [
      [[0, 0, 0], [10, 0, 0], [10, 10, 0]],
      [[0, 0, 0], [10, 10, 0], [0, 10, 0]]
    ]
    @loops = [
      [[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0]]
    ]
  end

  def test_semantic_fingerprint_ignores_triangle_and_loop_order
    first = fingerprint(@triangles, @loops)
    reordered_triangles = @triangles.reverse.map(&:reverse)
    rotated_reversed_loop = [@loops.first.rotate(2).reverse]
    second = fingerprint(reordered_triangles, rotated_reversed_loop)

    assert_equal first[:semantic_fingerprint], second[:semantic_fingerprint]
    refute_equal first[:ordered_fingerprint], second[:ordered_fingerprint]
  end

  def test_semantic_fingerprint_changes_when_preserved_boundary_changes
    first = fingerprint(@triangles, @loops)
    changed_loops = [
      [[0, 0, 0], [10, 0, 0], [9, 10, 0], [0, 10, 0]]
    ]
    second = fingerprint(@triangles, changed_loops)

    refute_equal first[:semantic_fingerprint], second[:semantic_fingerprint]
  end

  def test_probe_records_safe_repeated_success_without_bypassing_validation
    normalizer = FakeNormalizer.new
    normalizer.queue_outcomes(:success, :success)

    normalizer.run_normalize do |instance|
      2.times do
        assert_equal :keys,
                     instance.run_validation([], @loops, triangle_keys: @triangles)
      end
    end

    summary = normalizer.profile.fetch(
      LvnSourceBoundaryValidationReuseProbe::PROFILE_KEY
    )
    assert_equal 2, summary[:calls]
    assert_equal 1, summary[:unique_semantic_inputs]
    assert_equal 1, summary[:semantic_repeat_calls]
    assert_equal 1, summary[:ordered_repeat_calls]
    assert_equal 1, summary[:safe_success_repeat_calls]
    assert_equal 0, summary[:mixed_outcome_groups]
    assert_operator summary[:validation_seconds], :>=, 0.0
  end

  def test_mixed_outcome_is_never_counted_as_safe_reuse
    normalizer = FakeNormalizer.new
    normalizer.queue_outcomes(:first_failure, :success)

    normalizer.run_normalize do |instance|
      assert_raises(RuntimeError) do
        instance.run_validation([], @loops, triangle_keys: @triangles)
      end
      assert_equal :keys,
                   instance.run_validation([], @loops, triangle_keys: @triangles)
    end

    summary = normalizer.profile.fetch(
      LvnSourceBoundaryValidationReuseProbe::PROFILE_KEY
    )
    assert_equal 1, summary[:semantic_repeat_calls]
    assert_equal 1, summary[:mixed_outcome_groups]
    assert_equal 0, summary[:safe_success_repeat_calls]
    assert_equal 0.0, summary[:safe_success_repeat_validation_seconds]
  end

  def test_records_and_triangle_keys_share_semantic_fingerprint
    point_records = @triangles.map do |triangle|
      { points: triangle.map { |x, y, z| Point.new(x, y, z) } }
    end
    from_records = LvnSourceBoundaryValidationReuseProbe.fingerprint_input(
      point_records,
      @loops,
      point_key_builder: ->(point) { [point.x, point.y, point.z] }
    )
    from_keys = fingerprint(@triangles, @loops)

    assert_equal from_keys[:semantic_fingerprint],
                 from_records[:semantic_fingerprint]
  end

  private

  def fingerprint(triangles, loops)
    LvnSourceBoundaryValidationReuseProbe.fingerprint_input(
      [],
      loops,
      triangle_keys: triangles
    )
  end
end
