# frozen_string_literal: true

require 'minitest/autorun'

# Minimal SketchUp-compatible rigid XY transformations for a plain Ruby test.
unless defined?(Geom::Transformation)
  module Geom
    class Transformation
      def initialize(values = nil)
        values ||= [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        @x, @y = values[12], values[13]
        @angle = Math.atan2(values[1], values[0])
      end

      def self.frame(x, y, angle = 0.0)
        c, s = Math.cos(angle), Math.sin(angle)
        new([c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, x, y, 0, 1])
      end

      def *(other)
        c, s = Math.cos(@angle), Math.sin(@angle)
        self.class.frame(
          @x + c * other.x - s * other.y,
          @y + s * other.x + c * other.y,
          @angle + other.angle
        )
      end

      def inverse
        c, s = Math.cos(@angle), Math.sin(@angle)
        self.class.frame(-c * @x - s * @y, s * @x - c * @y, -@angle)
      end

      def to_a
        c, s = Math.cos(@angle), Math.sin(@angle)
        [c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, @x, @y, 0, 1]
      end

      protected

      attr_reader :x, :y, :angle
    end
  end
end

module Sketchup
  class << self
    attr_accessor :active_model
  end
end

require_relative '../indoor3d/utils/transformation'

class TransformationActivePathTest < Minitest::Test
  Transform = ULOL::Indoor3DGmlModeler::Utils::Transformation

  class FakeGroup
    attr_accessor :transformation, :parent
    attr_reader :definition, :persistent_id

    def initialize(id)
      @persistent_id = id
      @definition = Object.new
    end

    def valid?
      true
    end
  end

  Model = Struct.new(:active_path, :edit_transform)

  def setup
    @model = Model.new
    Sketchup.active_model = @model
    Transform.clear_root_world_transform_cache(@model)
    @primal = FakeGroup.new(1)
    @first = FakeGroup.new(2)
    @second = FakeGroup.new(3)
    @first.parent = @primal.definition
    @second.parent = @primal.definition
    @root_frame = Geom::Transformation.frame(-2454.5669, 120, Math::PI / 6)
    @first_local = Geom::Transformation.frame(150, 20, Math::PI / 3)
    @second_local = Geom::Transformation.frame(320, -15, -Math::PI / 6)
  end

  def test_local_and_world_frames_stay_constant_across_all_edit_paths
    [nil, [@primal], [@primal, @first]].each do |path|
      set_context(path)
      assert_frame(@root_frame, Transform.root_transformation_in_model(@primal))
      [[@first, @first_local], [@second, @second_local]].each do |group, local|
        got_local = Transform.entity_transformation_in_root(group, @primal)
        assert_frame(local, got_local)
        assert_frame(@root_frame * local,
                     Transform.root_transformation_in_model(@primal) * got_local)
      end
    end
  end

  def test_primal_movement_refreshes_frame_before_nested_edit
    set_context(nil)
    Transform.root_transformation_in_model(@primal)
    @root_frame = Geom::Transformation.frame(850, -10, -Math::PI / 4)
    set_context([@primal])
    assert_frame(@root_frame, Transform.root_transformation_in_model(@primal))
    set_context([@primal, @first])
    assert_frame(@root_frame, Transform.root_transformation_in_model(@primal))
    assert_frame(@second_local, Transform.entity_transformation_in_root(@second, @primal))
  end

  def test_nested_edit_without_observed_parent_raises_instead_of_guessing
    set_context([@primal, @first])
    assert_raises(Transform::RootWorldTransformUnavailableError) do
      Transform.root_transformation_in_model(@primal)
    end
    assert_raises(Transform::RootWorldTransformUnavailableError) do
      Transform.entity_transformation_in_root(@second, @primal)
    end
  end

  def test_model_cache_reset_prevents_stale_world_frames
    set_context(nil)
    Transform.root_transformation_in_model(@primal)
    Transform.clear_root_world_transform_cache(@model)
    set_context([@primal, @first])
    assert_raises(Transform::RootWorldTransformUnavailableError) do
      Transform.root_transformation_in_model(@primal)
    end
  end

  private

  def set_context(path)
    @model.active_path = path
    @primal.transformation = path ? Geom::Transformation.new : @root_frame
    @model.edit_transform = if path&.last == @first
                              @root_frame * @first_local
                            else
                              @root_frame
                            end
    [[@first, @first_local], [@second, @second_local]].each do |group, local|
      group.transformation = if path.nil?
                               local
                             elsif path.last == group
                               Geom::Transformation.new
                             else
                               @root_frame * local
                             end
    end
  end

  def assert_frame(expected, actual)
    expected.to_a.zip(actual.to_a).each do |first, second|
      assert_in_delta first, second, 1.0e-7
    end
  end
end
