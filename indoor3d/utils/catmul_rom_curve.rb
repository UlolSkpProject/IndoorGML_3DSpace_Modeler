module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Math
        module CatmullRom
                    
          def self.catmull_rom_point(p0, p1, p2, p3, t)
            t2 = t * t
            t3 = t2 * t
            
            # 중복 연산 줄이기 위해 계수 미리 계산
            c0 = 0.5 * (   -p0.x + 3 * p1.x - 3 * p2.x + p3.x)
            c1 = 0.5 * (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x)
            c2 = 0.5 * (   -p0.x            +     p2.x       )
            c3 = p1.x
            x = c0 * t3 + c1 * t2 + c2 * t + c3
                  
            c0 = 0.5 * (   -p0.y + 3 * p1.y - 3 * p2.y + p3.y)
            c1 = 0.5 * (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y)
            c2 = 0.5 * (   -p0.y            +     p2.y       )
            c3 = p1.y
            y = c0 * t3 + c1 * t2 + c2 * t + c3
                  
            c0 = 0.5 * (   -p0.z + 3 * p1.z - 3 * p2.z + p3.z)
            c1 = 0.5 * (2 * p0.z - 5 * p1.z + 4 * p2.z - p3.z)
            c2 = 0.5 * (   -p0.z            +     p2.z       )
            c3 = p1.z
            z = c0 * t3 + c1 * t2 + c2 * t + c3
                  
            Geom::Point3d.new(x, y, z)
          end
      
          # 여러 개의 점 배열을 받아 Overlay용 부드러운 점 배열(세그먼트)로 반환
          def self.generate_spline(points, segments_per_section = 20)
            return [] if points.size < 2
            
            # 가상의 시작점과 끝점을 추가하여 양 끝단 점도 통과할 수 있게 처리
            p_array = [points.first] + points + [points.last]
            spline_points = []
            
            num_sections = p_array.size - 4
            
            (0..num_sections).each do |i|
              p0, p1, p2, p3 = p_array[i], p_array[i+1], p_array[i+2], p_array[i+3]
              
              # 마지막 섹션이 아니라면, t=1.0(다음 섹션의 t=0.0과 중복)은 제외하고 추가
              is_last_section = (i == num_sections)
              max_j = is_last_section ? segments_per_section : (segments_per_section - 1)
              
              (0..max_j).each do |j|
                t = j.to_f / segments_per_section
                spline_points << catmull_rom_point(p0, p1, p2, p3, t)
              end
            end
            
            # 무거운 .uniq 호출 없이 깔끔한 배열 반환
            spline_points
          end

        end
      end
    end
  end
end