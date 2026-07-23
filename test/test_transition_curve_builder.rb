# frozen_string_literal: true

require 'minitest/autorun'

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def distance(other)
      Math.sqrt(((x - other.x)**2) + ((y - other.y)**2) + ((z - other.z)**2))
    end

    def vector_to(other)
      Vector3d.new(other.x - x, other.y - y, other.z - z)
    end

    def -(other)
      Vector3d.new(x - other.x, y - other.y, z - other.z)
    end
  end

  class Vector3d
    attr_accessor :x, :y, :z

    def initialize(x, y, z)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def length
      Math.sqrt((x**2) + (y**2) + (z**2))
    end

    def length=(value)
      normalize!
      @x *= value
      @y *= value
      @z *= value
    end

    def normalize!
      len = length
      return self if len <= 0.001

      @x /= len
      @y /= len
      @z /= len
      self
    end

    def dot(other)
      (x * other.x) + (y * other.y) + (z * other.z)
    end

    def clone
      self.class.new(x, y, z)
    end
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end

    module Utils
      module Math
        module HermiteSpline
          def self.calls
            @calls ||= []
          end

          def self.reset
            @calls = []
          end
        end
      end
    end
  end
end

require_relative '../indoor3d/ui/overlays/builders/transition_curve_builder'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class TransitionCurveBuilderTest < Minitest::Test
        def setup
          spline = Utils::Math::HermiteSpline
          @original_generate_segment = spline.method(:generate_segment) if spline.respond_to?(:generate_segment)
          spline.define_singleton_method(:generate_segment) do |point1, point2, _tangent1, _tangent2, segment_count|
            calls << [point1, point2, segment_count]
            [point1, point2]
          end
          Utils::Math::HermiteSpline.reset
        end

        def teardown
          spline = Utils::Math::HermiteSpline
          if @original_generate_segment
            original = @original_generate_segment
            spline.define_singleton_method(:generate_segment) do |*args, **kwargs|
              kwargs.empty? ? original.call(*args) : original.call(*args, **kwargs)
            end
          elsif spline.respond_to?(:generate_segment)
            class << spline
              remove_method :generate_segment
            end
          end
        end

        def test_transition_without_waypoint_uses_polyline_segment
          point1 = Geom::Point3d.new(0, 0, 0)
          point2 = Geom::Point3d.new(10, 0, 0)
          transition = fake_transition(point1: point1, point2: point2)
          builder = TransitionCurveBuilder.new(
            indoor_model: fake_indoor_model([transition]),
            transform_context: identity_transform_context
          )

          assert_equal [point1, point2], builder.transition_line_points
          assert_empty Utils::Math::HermiteSpline.calls
        end

        def test_transition_with_waypoint_and_normals_uses_hermite_segments
          point1 = Geom::Point3d.new(0, 0, 0)
          waypoint = Geom::Point3d.new(5, 5, 0)
          point2 = Geom::Point3d.new(10, 0, 0)
          transition = fake_transition(
            point1: point1,
            point2: point2,
            waypoint: waypoint,
            normal1: Geom::Vector3d.new(0, 1, 0),
            normal2: Geom::Vector3d.new(0, 1, 0)
          )
          builder = TransitionCurveBuilder.new(
            indoor_model: fake_indoor_model([transition]),
            transform_context: identity_transform_context
          )

          assert_equal [point1, waypoint, point2, waypoint], builder.transition_line_points
          assert_equal 2, Utils::Math::HermiteSpline.calls.length
        end

        def test_invalidate_clears_cached_render_points
          point1 = Geom::Point3d.new(0, 0, 0)
          point2 = Geom::Point3d.new(10, 0, 0)
          transition = fake_transition(point1: point1, point2: point2)
          builder = TransitionCurveBuilder.new(
            indoor_model: fake_indoor_model([transition]),
            transform_context: identity_transform_context
          )

          first_points = builder.transition_line_points
          builder.invalidate
          second_points = builder.transition_line_points

          refute_same first_points, second_points
          assert_equal first_points, second_points
        end

        def test_repeated_draw_returns_same_render_array_without_rebuilding
          transition = fake_transition(
            point1: Geom::Point3d.new(0, 0, 0),
            point2: Geom::Point3d.new(10, 0, 0)
          )
          builder = TransitionCurveBuilder.new(
            indoor_model: fake_indoor_model([transition]),
            transform_context: identity_transform_context
          )
          build_count = 0
          original_build = builder.method(:build_render_transition_line_points)
          builder.define_singleton_method(:build_render_transition_line_points) do
            build_count += 1
            original_build.call
          end

          first_points = builder.transition_line_points
          second_points = builder.transition_line_points

          assert_same first_points, second_points
          assert_equal 1, build_count
        end

        def test_invalidate_rebuilds_final_points_and_per_transition_curve_cache
          transition = fake_transition(
            point1: Geom::Point3d.new(0, 0, 0),
            point2: Geom::Point3d.new(10, 0, 0),
            waypoint: Geom::Point3d.new(5, 5, 0),
            normal1: Geom::Vector3d.new(0, 1, 0),
            normal2: Geom::Vector3d.new(0, 1, 0)
          )
          builder = TransitionCurveBuilder.new(
            indoor_model: fake_indoor_model([transition]),
            transform_context: identity_transform_context
          )

          first_points = builder.transition_line_points
          assert_equal 2, Utils::Math::HermiteSpline.calls.length
          assert_same first_points, builder.transition_line_points
          assert_equal 2, Utils::Math::HermiteSpline.calls.length

          builder.invalidate
          refute_same first_points, builder.transition_line_points
          assert_equal 4, Utils::Math::HermiteSpline.calls.length
        end

        private

        def fake_transition(point1:, point2:, waypoint: nil, normal1: nil, normal2: nil)
          state1 = fake_state(point1)
          state2 = fake_state(point2)
          Struct.new(:id, :state1, :state2, :state1_point, :state2_point, :selected_waypoint,
                     :selected_waypoint_normal1, :selected_waypoint_normal2) do
            def valid?
              true
            end
          end.new('transition-1', state1, state2, point1, point2, waypoint, normal1, normal2)
        end

        def fake_state(position)
          Struct.new(:position) do
            def valid?
              true
            end
          end.new(position)
        end

        def fake_indoor_model(transitions)
          Struct.new(:transitions) do
            def dual_overlay_transition_visible?(_transition)
              true
            end
          end.new(transitions)
        end

        def identity_transform_context
          Class.new do
            def overlay_render_context_cache_key
              [:identity]
            end

            def rounded_point_key(point)
              return nil unless point

              [point.x.round(6), point.y.round(6), point.z.round(6)]
            end

            def rounded_vector_key(vector)
              return nil unless vector

              [vector.x.round(6), vector.y.round(6), vector.z.round(6)]
            end

            def overlay_state_root_local_point(state)
              state.position
            end

            def overlay_render_point(point)
              point
            end

            def overlay_render_vector(vector)
              vector
            end
          end.new
        end
      end
    end
  end
end
