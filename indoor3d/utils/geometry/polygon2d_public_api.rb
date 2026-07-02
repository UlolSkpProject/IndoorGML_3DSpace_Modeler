# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        def self.intersect_polygons_2d(subject_polygon, clipping_polygon)
          send(:clip_polygon, subject_polygon, clipping_polygon)
        end unless respond_to?(:intersect_polygons_2d)

        def self.polygon_area_2d_value(points)
          send(:polygon_area_2d, points)
        end unless respond_to?(:polygon_area_2d_value)

        def self.point_in_polygon_2d?(point, polygon, tolerance = DEFAULT_TOLERANCE)
          send(:point_in_polygon?, point, polygon, tolerance)
        end unless respond_to?(:point_in_polygon_2d?)
      end
    end
  end
end
