# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        SHELL_CENTER_COARSE_DIVISIONS = 8 unless const_defined?(:SHELL_CENTER_COARSE_DIVISIONS, false)
        SHELL_CENTER_REFINE_DIVISIONS = 4 unless const_defined?(:SHELL_CENTER_REFINE_DIVISIONS, false)
        SHELL_CENTER_TOLERANCE = 0.001 unless const_defined?(:SHELL_CENTER_TOLERANCE, false)
        DEFAULT_TOLERANCE = 0.001 unless const_defined?(:DEFAULT_TOLERANCE, false)

        def self.polygon_normal(points, epsilon: DEFAULT_TOLERANCE)
          x = 0.0
          y = 0.0
          z = 0.0
          points.each_with_index do |point, index|
            next_point = points[(index + 1) % points.length]
            x += (point.y - next_point.y) * (point.z + next_point.z)
            y += (point.z - next_point.z) * (point.x + next_point.x)
            z += (point.x - next_point.x) * (point.y + next_point.y)
          end
          normal = Geom::Vector3d.new(x, y, z)
          return nil if normal.length <= epsilon

          normal.normalize!
          normal
        end
      end
    end
  end
end

require_relative 'geometry/polygon2d'
require_relative 'geometry/adjacency_detector'
require_relative 'geometry/shell_analyzer'
require_relative 'geometry/source_group'
