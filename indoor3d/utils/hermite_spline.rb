# frozen_string_literal: true

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

          def self.generate_segment(p0, p1, tangent0, tangent1, segments = 8, include_start: true, refine: true)
            base_ts = (0..segments).map { |i| i.to_f / segments }
            unless refine
              start_index = include_start ? 0 : 1
              return base_ts[start_index..-1].map { |t| point(p0, p1, tangent0, tangent1, t) }
            end

            # Base samples are required for bend estimation. Reuse those exact
            # Point3d objects in the final result instead of evaluating the same
            # Hermite positions a second time after refinement.
            base_points = base_ts.map { |t| point(p0, p1, tangent0, tangent1, t) }
            refined_points = []
            refined_points << base_points.first if include_start

            index = 0
            last_index = base_ts.length - 1
            while index < last_index
              t_a = base_ts[index]
              t_b = base_ts[index + 1]
              bend = index.zero? ? 0.0 : bend_factor(
                base_points[index - 1],
                base_points[index],
                base_points[index + 1]
              )
              extra = (bend * 3).round.clamp(0, 4)

              extra_index = 0
              while extra_index < extra
                t = t_a + ((t_b - t_a) * (extra_index + 1).to_f / (extra + 1))
                refined_points << point(p0, p1, tangent0, tangent1, t)
                extra_index += 1
              end

              refined_points << base_points[index + 1]
              index += 1
            end

            refined_points
          end

          def self.bend_factor(pa, pb, pc)
            v1 = (pb - pa); v1.normalize!
            v2 = (pc - pb); v2.normalize!
            1.0 - v1.dot(v2)  # 0=직선, 클수록 많이 꺾임
          end
        end
      end
    end
  end
end
