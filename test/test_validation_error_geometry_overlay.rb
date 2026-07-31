# frozen_string_literal: true

require 'minitest/autorun'

GL_TRIANGLES = 4 unless defined?(GL_TRIANGLES)
GL_LINES = 1 unless defined?(GL_LINES)

module Sketchup
  class Color
    def initialize(*); end
  end unless const_defined?(:Color, false)
end

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end unless const_defined?(:Point3d, false)

  class BoundingBox
    attr_reader :add_calls

    def initialize
      @points = []
      @add_calls = 0
    end

    def add(point)
      @add_calls += 1
      @points << point
      self
    end

    def empty?
      @points.empty?
    end

    def min
      Point3d.new(
        @points.map(&:x).min,
        @points.map(&:y).min,
        @points.map(&:z).min
      )
    end

    def max
      Point3d.new(
        @points.map(&:x).max,
        @points.map(&:y).max,
        @points.map(&:z).max
      )
    end
  end unless const_defined?(:BoundingBox, false)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)

      class SpaceOverlay
        def initialize(*); end

        private

        def renderable_active_context?
          true
        end
      end unless const_defined?(:SpaceOverlay)
    end
  end
end

require_relative '../indoor3d/ui/overlays/validation_error_geometry_overlay'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ValidationErrorGeometryOverlayTest < Minitest::Test
        class CountingArray < Array
          attr_reader :flatten_calls

          def initialize(values)
            super(values)
            @flatten_calls = 0
          end

          def flatten(level = nil)
            @flatten_calls += 1
            level.nil? ? super() : super(level)
          end
        end

        def test_geometry_points_are_precomputed_and_reused
          overlay = build_overlay
          geometry = sample_geometry

          overlay.set_geometry(geometry)
          first = overlay.send(:geometry_points)
          second = overlay.send(:geometry_points)

          assert_same first, second
          assert_equal 14, first.length
        end

        def test_draw_reuses_preflattened_triangle_points
          overlay = build_overlay
          geometry = sample_geometry(counting_triangles: true)
          face_triangles = geometry[:face_triangles]
          overlap_triangles = geometry[:overlap_triangles]

          overlay.set_geometry(geometry)
          assert_equal 1, face_triangles.flatten_calls
          assert_equal 1, overlap_triangles.flatten_calls

          view = recording_view
          overlay.draw(view)

          assert_equal 1, face_triangles.flatten_calls
          assert_equal 1, overlap_triangles.flatten_calls
          assert_equal 4, view.draw_calls.length
          assert_equal GL_TRIANGLES, view.draw_calls[0][:mode]
          assert_equal 6, view.draw_calls[0][:points].length
          assert_equal GL_LINES, view.draw_calls[1][:mode]
          assert_equal GL_TRIANGLES, view.draw_calls[2][:mode]
          assert_equal GL_LINES, view.draw_calls[3][:mode]
        end

        def test_get_extents_adds_only_cached_min_and_max
          overlay = build_overlay
          overlay.set_geometry(sample_geometry)

          bounds = overlay.getExtents

          assert_equal 2, bounds.add_calls
          assert_in_delta(-4.0, bounds.min.x, 0.001)
          assert_in_delta(-2.0, bounds.min.y, 0.001)
          assert_in_delta(-3.0, bounds.min.z, 0.001)
          assert_in_delta(10.0, bounds.max.x, 0.001)
          assert_in_delta(11.0, bounds.max.y, 0.001)
          assert_in_delta(12.0, bounds.max.z, 0.001)
        end

        def test_clear_resets_render_and_extent_caches
          overlay = build_overlay
          overlay.set_geometry(sample_geometry)
          overlay.clear

          assert_empty overlay.send(:geometry_points)
          bounds = overlay.getExtents
          assert_equal 0, bounds.add_calls

          view = recording_view
          overlay.draw(view)
          assert_empty view.draw_calls
        end

        private

        def build_overlay
          indoor_model = Struct.new(:focus_active) do
            def validation_focus_active?
              focus_active
            end
          end.new(true)
          ValidationErrorGeometryOverlay.new(indoor_model)
        end

        def sample_geometry(counting_triangles: false)
          face = [
            point(0, 0, 0), point(2, 0, 0), point(0, 3, 0),
            point(10, 11, 12), point(8, 11, 12), point(10, 9, 12)
          ].each_slice(3).to_a
          overlap = [
            point(-4, -2, -3), point(-1, -2, -3), point(-4, 1, -3)
          ].each_slice(3).to_a

          face = CountingArray.new(face) if counting_triangles
          overlap = CountingArray.new(overlap) if counting_triangles

          {
            face_triangles: face,
            face_edges: [point(0, 0, 0), point(2, 0, 0)],
            overlap_triangles: overlap,
            overlap_edges: [point(-4, -2, -3), point(-1, -2, -3), point(8, 9, 10)]
          }
        end

        def point(x, y, z)
          Geom::Point3d.new(x, y, z)
        end

        def recording_view
          Class.new do
            attr_accessor :drawing_color, :line_width, :line_stipple
            attr_reader :draw_calls

            def initialize
              @draw_calls = []
            end

            def draw(mode, points)
              @draw_calls << { mode: mode, points: points }
            end
          end.new
        end
      end
    end
  end
end
