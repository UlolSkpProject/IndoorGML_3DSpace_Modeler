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
          def self.generate_segment(point1, point2, _tangent1, _tangent2, _segment_count)
            [point1, point2]
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
      class TransitionCurveBuilderRenderSnapshotTest < Minitest::Test
        def test_cold_rebuild_reuses_one_render_snapshot_for_all_transition_transforms
          transitions = [
            transition('t1', 0.0),
            transition('t2', 20.0)
          ]
          context = snapshot_transform_context
          builder = TransitionCurveBuilder.new(
            indoor_model: indoor_model(transitions),
            transform_context: context
          )

          points = builder.transition_line_points

          refute_empty points
          assert_equal 1, context.snapshot_calls
          assert_equal 6, context.snapshot_point_calls
          assert_equal 4, context.snapshot_vector_calls
          assert_equal 0, context.render_point_calls
          assert_equal 0, context.render_vector_calls
          assert_equal 0, context.cache_key_calls
        end

        def test_soft_invalidate_reuses_cached_segments_without_snapshot_transforms
          transitions = [transition('t1', 0.0)]
          context = snapshot_transform_context
          builder = TransitionCurveBuilder.new(
            indoor_model: indoor_model(transitions),
            transform_context: context
          )

          first = builder.transition_line_points
          assert_equal 1, context.snapshot_calls
          assert_equal 3, context.snapshot_point_calls
          assert_equal 2, context.snapshot_vector_calls

          builder.invalidate
          second = builder.transition_line_points

          refute_same first, second
          assert_equal first, second
          assert_equal 2, context.snapshot_calls
          assert_equal 3, context.snapshot_point_calls
          assert_equal 2, context.snapshot_vector_calls
        end

        private

        def transition(id, offset)
          point1 = Geom::Point3d.new(offset, 0, 0)
          waypoint = Geom::Point3d.new(offset + 5, 5, 0)
          point2 = Geom::Point3d.new(offset + 10, 0, 0)
          state1 = Struct.new(:position).new(point1)
          state2 = Struct.new(:position).new(point2)
          Struct.new(
            :id,
            :state1,
            :state2,
            :state1_point,
            :state2_point,
            :selected_waypoint,
            :selected_waypoint_normal1,
            :selected_waypoint_normal2
          ).new(
            id,
            state1,
            state2,
            point1,
            point2,
            waypoint,
            Geom::Vector3d.new(0, 1, 0),
            Geom::Vector3d.new(0, 1, 0)
          )
        end

        def indoor_model(transitions)
          Struct.new(:transitions) do
            def dual_overlay_transition_visible?(_transition)
              true
            end
          end.new(transitions)
        end

        def snapshot_transform_context
          Class.new do
            attr_reader :snapshot_calls,
                        :snapshot_point_calls,
                        :snapshot_vector_calls,
                        :render_point_calls,
                        :render_vector_calls,
                        :cache_key_calls

            def initialize
              @snapshot_calls = 0
              @snapshot_point_calls = 0
              @snapshot_vector_calls = 0
              @render_point_calls = 0
              @render_vector_calls = 0
              @cache_key_calls = 0
            end

            def overlay_render_context_snapshot
              @snapshot_calls += 1
              { transformation: :identity, cache_key: [:identity] }
            end

            def overlay_render_context_cache_key
              @cache_key_calls += 1
              [:legacy]
            end

            def overlay_render_point_from_snapshot(point, _snapshot)
              @snapshot_point_calls += 1
              point
            end

            def overlay_render_vector_from_snapshot(vector, _snapshot)
              @snapshot_vector_calls += 1
              vector
            end

            def overlay_render_point(point)
              @render_point_calls += 1
              point
            end

            def overlay_render_vector(vector)
              @render_vector_calls += 1
              vector
            end

            def overlay_state_root_local_point(state)
              state.position
            end

            def rounded_point_key(point)
              return nil unless point

              [point.x.round(6), point.y.round(6), point.z.round(6)]
            end

            def rounded_vector_key(vector)
              return nil unless vector

              [vector.x.round(6), vector.y.round(6), vector.z.round(6)]
            end
          end.new
        end
      end
    end
  end
end
