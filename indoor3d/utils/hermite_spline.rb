module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Math
        module HermiteSpline
          def self.point(p0, p1, tangent0, tangent1, t)
            t2 = t * t
            t3 = t2 * t
            h00 = (2.0 * t3) - (3.0 * t2) + 1.0
            h10 = t3 - (2.0 * t2) + t
            h01 = (-2.0 * t3) + (3.0 * t2)
            h11 = t3 - t2

            Geom::Point3d.new(
              (h00 * p0.x) + (h10 * tangent0.x) + (h01 * p1.x) + (h11 * tangent1.x),
              (h00 * p0.y) + (h10 * tangent0.y) + (h01 * p1.y) + (h11 * tangent1.y),
              (h00 * p0.z) + (h10 * tangent0.z) + (h01 * p1.z) + (h11 * tangent1.z)
            )
          end

          def self.generate_segment(p0, p1, tangent0, tangent1, segments = 8, include_start: true)
            segments = [segments.to_i, 1].max
            start_index = include_start ? 0 : 1
            (start_index..segments).map do |index|
              point(p0, p1, tangent0, tangent1, index.to_f / segments)
            end
          end
        end
      end
    end
  end
end
