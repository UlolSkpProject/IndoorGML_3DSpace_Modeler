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
            # 1단계: 기본 t값들 생성
            base_ts = (0..segments).map { |i| i.to_f / segments }
            unless refine
              start_index = include_start ? 0 : 1
              return base_ts[start_index..-1].map { |t| point(p0, p1, tangent0, tangent1, t) }
            end
            
            # 2단계: 각 구간의 "꺾임 정도"로 가중치 계산
            points = base_ts.map { |t| point(p0, p1, tangent0, tangent1, t) }
            
            refined_ts = [base_ts.first]
            base_ts.each_cons(2).with_index do |(t_a, t_b), i|
              bend = i.zero? ? 0.0 : bend_factor(points[i - 1], points[i], points[i + 1])
              extra = (bend * 3).round.clamp(0, 4)  # 꺾임 클수록 추가 분할
              extra.times do |k|
                refined_ts << t_a + (t_b - t_a) * (k+1).to_f / (extra+1)
              end
              refined_ts << t_b
            end
            
            start_index = include_start ? 0 : 1
            refined_ts.uniq.sort[start_index..-1].map { |t| point(p0, p1, tangent0, tangent1, t) }
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
