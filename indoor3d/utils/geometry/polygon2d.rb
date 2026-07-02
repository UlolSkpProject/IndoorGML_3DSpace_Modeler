# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        def self.intersect_polygons_2d(subject_polygon, clipping_polygon)
          clip_polygon(subject_polygon, clipping_polygon)
        end

        def self.polygon_area_2d_value(points)
          polygon_area_2d(points)
        end

        def self.point_in_polygon_2d?(point, polygon, tolerance = DEFAULT_TOLERANCE)
          point_in_polygon?(point, polygon, tolerance)
        end

        def self.clip_polygon(subject_polygon, clip_polygon)
          return [] if subject_polygon.empty? || clip_polygon.length < 3

          clip_sign = polygon_area_2d(clip_polygon) < 0.0 ? -1.0 : 1.0
          output = subject_polygon
          clip_polygon.each_index do |index|
            clip_start = clip_polygon[index]
            clip_end = clip_polygon[(index + 1) % clip_polygon.length]
            input = output
            output = []
            break if input.empty?

            previous = input.last
            input.each do |current|
              current_inside = inside_clip_edge?(current, clip_start, clip_end, clip_sign)
              previous_inside = inside_clip_edge?(previous, clip_start, clip_end, clip_sign)
              if current_inside
                output << line_intersection_2d(previous, current, clip_start, clip_end) unless previous_inside
                output << current
              elsif previous_inside
                output << line_intersection_2d(previous, current, clip_start, clip_end)
              end
              previous = current
            end
            output.compact!
          end
          output
        end
        private_class_method :clip_polygon

        def self.inside_clip_edge?(point, edge_start, edge_end, clip_sign)
          clip_sign * orientation(edge_start, edge_end, point) >= -0.000001
        end
        private_class_method :inside_clip_edge?

        def self.line_intersection_2d(line1_start, line1_end, line2_start, line2_end)
          x1, y1 = line1_start
          x2, y2 = line1_end
          x3, y3 = line2_start
          x4, y4 = line2_end
          denominator = ((x1 - x2) * (y3 - y4)) - ((y1 - y2) * (x3 - x4))
          return line1_end if denominator.abs <= 0.000001

          px = ((((x1 * y2) - (y1 * x2)) * (x3 - x4)) - ((x1 - x2) * ((x3 * y4) - (y3 * x4)))) / denominator
          py = ((((x1 * y2) - (y1 * x2)) * (y3 - y4)) - ((y1 - y2) * ((x3 * y4) - (y3 * x4)))) / denominator
          [px, py]
        end
        private_class_method :line_intersection_2d

        def self.polygon_area_2d(points)
          return 0.0 if points.length < 3

          points.each_index.sum do |index|
            next_point = points[(index + 1) % points.length]
            (points[index][0] * next_point[1]) - (next_point[0] * points[index][1])
          end / 2.0
        end
        private_class_method :polygon_area_2d

        def self.polygon_centroid_2d(points)
          area_factor = 0.0
          centroid_x = 0.0
          centroid_y = 0.0
          points.each_index do |index|
            point = points[index]
            next_point = points[(index + 1) % points.length]
            cross = (point[0] * next_point[1]) - (next_point[0] * point[1])
            area_factor += cross
            centroid_x += (point[0] + next_point[0]) * cross
            centroid_y += (point[1] + next_point[1]) * cross
          end
          return vertex_average_2d(points) if area_factor.abs <= 0.000001

          [centroid_x / (3.0 * area_factor), centroid_y / (3.0 * area_factor)]
        end
        private_class_method :polygon_centroid_2d

        def self.vertex_average_2d(points)
          [points.map(&:first).sum / points.length.to_f, points.map(&:last).sum / points.length.to_f]
        end
        private_class_method :vertex_average_2d
        def self.polygon_edges(polygon)
          polygon.each_index.map do |index|
            [polygon[index], polygon[(index + 1) % polygon.length]]
          end
        end
        private_class_method :polygon_edges

        def self.point_in_polygon?(point, polygon, tolerance)
          return true if polygon_edges(polygon).any? { |edge| point_on_segment?(point, edge, tolerance) }

          inside = false
          j = polygon.length - 1
          polygon.each_index do |i|
            xi, yi = polygon[i]
            xj, yj = polygon[j]
            intersects = ((yi > point[1]) != (yj > point[1])) &&
                         (point[0] < ((xj - xi) * (point[1] - yi) / (yj - yi)) + xi)
            inside = !inside if intersects
            j = i
          end
          inside
        end
        private_class_method :point_in_polygon?

        def self.point_on_segment?(point, edge, tolerance)
          p1, p2 = edge
          cross = ((point[1] - p1[1]) * (p2[0] - p1[0])) - ((point[0] - p1[0]) * (p2[1] - p1[1]))
          return false if cross.abs > tolerance

          min_x, max_x = [p1[0], p2[0]].minmax
          min_y, max_y = [p1[1], p2[1]].minmax
          point[0] >= min_x - tolerance && point[0] <= max_x + tolerance &&
            point[1] >= min_y - tolerance && point[1] <= max_y + tolerance
        end
        private_class_method :point_on_segment?

        def self.orientation(point1, point2, point3)
          ((point2[0] - point1[0]) * (point3[1] - point1[1])) -
            ((point2[1] - point1[1]) * (point3[0] - point1[0]))
        end
        private_class_method :orientation
      end
    end
  end
end
