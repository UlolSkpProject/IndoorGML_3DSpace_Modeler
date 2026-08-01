# frozen_string_literal: true

require 'time'

base_probe_path = File.join(__dir__, 'lvn_large_solid_face_detail_log_probe.rb')
unless defined?(
  ULOL::Indoor3DGmlModeler::IndoorCore::LvnLargeSolidFaceDetailLogProbe
)
  source = File.binread(base_probe_path).force_encoding(Encoding::UTF_8)
  pattern = %r{
    \n\s*reset_progress\s*\n\s*BASE\.run\s*\n\s*end\s*\n\s*end\s*\n\s*end\s*\n\s*end\s*\z
  }mx
  replacement = <<~'TAIL'

        reset_progress
      end
    end
  end
end
  TAIL
  stripped = source.sub(pattern, replacement)
  raise "Could not suppress default run in #{base_probe_path}" if stripped == source

  TOPLEVEL_BINDING.eval(stripped, base_probe_path, 1)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnBridgeNearestFirstProbe
        BASE = LvnLargeSolidDetailedLogProbe
        DETAIL = LvnLargeSolidFaceDetailLogProbe

        module_function

        def log(event, data = {}, level: 'INFO')
          BASE.active_context&.log(event, data, level: level)
        end

        module NearestFirstBridge
          private

          def bridge_exact_hole(polygon, hole, outer_2d, holes_2d, drop_axis)
            hole_index = hole.each_index.max_by do |index|
              point = integer_project_2d(hole[index], drop_axis)
              [point[0], -point[1]]
            end
            hole_point = hole[hole_index]
            hole_point_2d = integer_project_2d(hole_point, drop_axis)
            polygon_2d = polygon.map do |point|
              integer_project_2d(point, drop_axis)
            end
            all_loops = [polygon_2d] + holes_2d

            ordered_candidates = polygon.each_index.filter_map do |polygon_index|
              polygon_point_2d = polygon_2d[polygon_index]
              next if polygon_point_2d == hole_point_2d

              delta = integer_subtract_2d(
                polygon_point_2d,
                hole_point_2d
              )
              [
                integer_dot_2d(delta, delta),
                polygon_index,
                polygon_point_2d
              ]
            end.sort_by do |distance_squared, polygon_index, _point|
              [distance_squared, polygon_index]
            end

            visibility_calls = 0
            selected = ordered_candidates.find do |_distance_squared, _polygon_index, point_2d|
              visibility_calls += 1
              exact_bridge_visible?(
                hole_point_2d,
                point_2d,
                all_loops,
                outer_2d,
                holes_2d
              )
            end

            unless selected
              raise ReconstructionError,
                    'Could not connect an exact coplanar patch hole to its exterior boundary'
            end

            distance_squared, polygon_index, = selected
            LvnBridgeNearestFirstProbe.log(
              'NEAREST_FIRST_BRIDGE_SELECTED',
              {
                polygon_vertex_count: polygon.length,
                hole_vertex_count: hole.length,
                candidate_count: ordered_candidates.length,
                visibility_calls: visibility_calls,
                selected_polygon_index: polygon_index,
                selected_distance_squared: distance_squared
              }
            )

            polygon_point = polygon[polygon_index]
            rotated_hole = hole[hole_index..] + hole[0...hole_index]
            polygon[0..polygon_index] +
              rotated_hole +
              [hole_point, polygon_point] +
              Array(polygon[(polygon_index + 1)..])
          end
        end

        LocalVertexNormalizer.prepend(NearestFirstBridge) unless
          LocalVertexNormalizer.ancestors.include?(NearestFirstBridge)

        DETAIL.reset_progress
        BASE.run
      end
    end
  end
end
