# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        class ReconstructionError < StandardError; end
        class TopologyChangedError < StandardError; end

        def initialize
          @tolerance_mm = 0.001
        end

        private

        def retriangulate_exact_coplanar_patches(
          records,
          forced_source_face_keys: [],
          force_all: false
        )
          [
            records,
            {
              detected_patches: exact_coplanar_triangle_patches(records).length,
              forced_source_face_keys: forced_source_face_keys,
              force_all: force_all
            }
          ]
        end

        def grid_indices(point)
          point
        end

        def canonical_edge_key(first, second)
          [first, second].sort
        end

        def integer_subtract(first, second)
          [
            first[0] - second[0],
            first[1] - second[1],
            first[2] - second[2]
          ]
        end

        def integer_cross(first, second)
          [
            (first[1] * second[2]) - (first[2] * second[1]),
            (first[2] * second[0]) - (first[0] * second[2]),
            (first[0] * second[1]) - (first[1] * second[0])
          ]
        end

        def integer_dot(first, second)
          first.zip(second).sum { |a, b| a * b }
        end

        def vector_dot(first, second)
          first.zip(second).sum { |a, b| a * b }
        end

        def vector_length(vector)
          Math.sqrt(vector_dot(vector, vector))
        end

        def integer_triangle_normal(triangle)
          integer_cross(
            integer_subtract(triangle[1], triangle[0]),
            integer_subtract(triangle[2], triangle[0])
          )
        end

        def integer_zero_vector?(vector)
          vector.all?(&:zero?)
        end

        def exact_triangle_minimum_altitude_mm(triangle)
          normal_length = Math.sqrt(
            integer_dot(
              integer_triangle_normal(triangle),
              integer_triangle_normal(triangle)
            ).to_f
          )
          longest_edge = 3.times.map do |index|
            edge = integer_subtract(
              triangle[index],
              triangle[(index + 1) % 3]
            )
            Math.sqrt(integer_dot(edge, edge).to_f)
          end.max
          return 0.0 unless longest_edge&.positive?

          (normal_length / longest_edge) * @tolerance_mm
        end

        def grid_triangle_sliver?(points)
          triangle = points.map { |point| grid_indices(point) }
          return true if triangle.uniq.length != 3
          return true if integer_zero_vector?(integer_triangle_normal(triangle))

          exact_triangle_minimum_altitude_mm(triangle) < @tolerance_mm
        end

        def exact_integer_plane_key(triangle)
          normal = integer_triangle_normal(triangle)
          raise ReconstructionError, 'zero plane' if integer_zero_vector?(normal)

          divisor =
            normal.map(&:abs).reject(&:zero?).reduce { |gcd, value| gcd.gcd(value) }
          primitive = normal.map { |value| value / divisor }
          first_nonzero = primitive.find { |value| !value.zero? }
          primitive = primitive.map(&:-@) if first_nonzero.negative?
          primitive + [integer_dot(primitive, triangle[0])]
        end

        def exact_coplanar_patch_key(record)
          triangle = record[:points].map { |point| grid_indices(point) }
          plane_key = exact_integer_plane_key(triangle)
          normal = plane_key.first(3)
          source_normal = Array(record[:source_normal]).map(&:to_f)
          orientation =
            if source_normal.length == 3 &&
               vector_dot(normal, source_normal).negative?
              -1
            else
              1
            end
          [plane_key, orientation]
        end

        def exact_coplanar_triangle_patches(records)
          grouped = records.group_by { |record| exact_coplanar_patch_key(record) }
          patches = []

          grouped.each_value do |group|
            owners = Hash.new { |hash, key| hash[key] = [] }
            group.each_with_index do |record, index|
              triangle = record[:points]
              3.times do |edge_index|
                owners[
                  canonical_edge_key(
                    triangle[edge_index],
                    triangle[(edge_index + 1) % 3]
                  )
                ] << index
              end
            end

            adjacency = Array.new(group.length) { [] }
            owners.each_value do |indices|
              next unless indices.length == 2

              first, second = indices
              adjacency[first] << second
              adjacency[second] << first
            end

            visited = Array.new(group.length, false)
            group.each_index do |seed|
              next if visited[seed]

              visited[seed] = true
              queue = [seed]
              component = []
              until queue.empty?
                index = queue.shift
                component << group[index]
                adjacency[index].each do |neighbor|
                  next if visited[neighbor]

                  visited[neighbor] = true
                  queue << neighbor
                end
              end
              patches << component
            end
          end

          patches
        end

        def exact_boundary_loops(boundary_edges)
          adjacency = Hash.new { |hash, key| hash[key] = [] }
          boundary_edges.each do |first, second|
            adjacency[first] << second
            adjacency[second] << first
          end
          raise TopologyChangedError, 'branched' if adjacency.any? do |_point, neighbors|
            neighbors.uniq.length != 2
          end

          unused = boundary_edges.to_h do |edge|
            [canonical_edge_key(edge[0], edge[1]), true]
          end
          loops = []
          until unused.empty?
            start_point, current = unused.keys.first
            previous = start_point
            loop_points = [start_point]
            unused.delete(canonical_edge_key(start_point, current))

            boundary_edges.length.times do
              loop_points << current
              break if current == start_point

              following = adjacency[current].find do |candidate|
                candidate != previous &&
                  unused[canonical_edge_key(current, candidate)]
              end
              following ||= adjacency[current].find do |candidate|
                unused[canonical_edge_key(current, candidate)]
              end
              raise TopologyChangedError, 'open' unless following

              unused.delete(canonical_edge_key(current, following))
              previous, current = current, following
            end

            raise TopologyChangedError, 'not closed' unless loop_points.last == start_point

            loop_points.pop
            loops << loop_points
          end
          loops
        end

        def integer_project_2d(point, drop_axis)
          point.each_index.filter_map do |axis|
            point[axis] unless axis == drop_axis
          end
        end

        def integer_orientation_2d(first, second, third)
          ((second[0] - first[0]) * (third[1] - first[1])) -
            ((second[1] - first[1]) * (third[0] - first[0]))
        end

        def integer_point_on_segment_2d?(point, first, second)
          return false unless integer_orientation_2d(first, second, point).zero?

          point[0].between?(*[first[0], second[0]].minmax) &&
            point[1].between?(*[first[1], second[1]].minmax)
        end

        def integer_segments_intersect_2d?(a1, a2, b1, b2)
          o1 = integer_orientation_2d(a1, a2, b1)
          o2 = integer_orientation_2d(a1, a2, b2)
          o3 = integer_orientation_2d(b1, b2, a1)
          o4 = integer_orientation_2d(b1, b2, a2)

          return true if o1.zero? && integer_point_on_segment_2d?(b1, a1, a2)
          return true if o2.zero? && integer_point_on_segment_2d?(b2, a1, a2)
          return true if o3.zero? && integer_point_on_segment_2d?(a1, b1, b2)
          return true if o4.zero? && integer_point_on_segment_2d?(a2, b1, b2)

          (o1.positive? != o2.positive?) &&
            (o3.positive? != o4.positive?)
        end

        def simple_integer_polygon_2d?(polygon)
          polygon.length.times do |first_index|
            first_next = (first_index + 1) % polygon.length
            ((first_index + 1)...polygon.length).each do |second_index|
              second_next = (second_index + 1) % polygon.length
              next if second_index == first_next
              next if first_index.zero? && second_next.zero?
              next unless (
                [polygon[first_index], polygon[first_next]] &
                [polygon[second_index], polygon[second_next]]
              ).empty?

              return false if integer_segments_intersect_2d?(
                polygon[first_index],
                polygon[first_next],
                polygon[second_index],
                polygon[second_next]
              )
            end
          end
          true
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/self_intersecting_sliver_repair_v2'

klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
normalizer = klass.new

a = [-29_985_561, -27_884_588, -749_991]
b = [-20_016_341, -27_628_845, -749_991]
x = [-24_562_351, -27_745_465, -749_991]
w = [-24_987_211, -27_756_364, -749_991]
y = [-29_560_701, -27_873_689, -749_991]
host_third = [-34_983_403, -28_012_799, -999_991]
floor_bx = [-24_554_914, -28_035_370, -749_991]
x_top = [-24_562_351, -27_745_465, 3_802_067]
floor_wy = [-29_553_264, -28_163_594, -749_991]
y_top = [-29_560_701, -27_873_689, 3_802_067]

vertical_normal = [0.025644882371886335, -0.9996711159216959, 6.07635113435366e-08]
floor_normal = [0.0, 0.0, -1.0]

records = [
  {
    points: [a, host_third, b],
    source_face_key: 100,
    source_polygon_index: 9,
    source_normal: vertical_normal
  },
  {
    points: [a, b, w],
    source_face_key: 100,
    source_polygon_index: 10,
    source_normal: vertical_normal
  },
  {
    points: [w, b, x],
    source_face_key: 100,
    source_polygon_index: 11,
    source_normal: vertical_normal
  },
  {
    points: [a, w, y],
    source_face_key: 100,
    source_polygon_index: 12,
    source_normal: vertical_normal
  },
  {
    points: [b, floor_bx, x],
    source_face_key: 200,
    source_polygon_index: 0,
    source_normal: floor_normal
  },
  {
    points: [x_top, w, x],
    source_face_key: 100,
    source_polygon_index: 3,
    source_normal: vertical_normal
  },
  {
    points: [w, floor_wy, y],
    source_face_key: 201,
    source_polygon_index: 0,
    source_normal: floor_normal
  },
  {
    points: [y_top, a, y],
    source_face_key: 100,
    source_polygon_index: 5,
    source_normal: vertical_normal
  }
]

repaired, report = normalizer.send(
  :retriangulate_exact_coplanar_patches,
  records
)

unless report[:folded_sliver_strip_repairs] == 1
  raise "expected one folded sliver repair: #{report.inspect}"
end
unless report[:folded_sliver_removed_triangles] == 3
  raise "expected three removed sliver triangles: #{report.inspect}"
end
unless report[:folded_sliver_replacement_triangles] == 4
  raise "expected four replacement fan triangles: #{report.inspect}"
end
unless repaired.length == records.length
  raise "repair changed total triangle count: #{records.length} -> #{repaired.length}"
end

edge_owners = Hash.new(0)
repaired.each do |record|
  triangle = record[:points]
  3.times do |index|
    edge = [triangle[index], triangle[(index + 1) % 3]].sort
    edge_owners[edge] += 1
  end
end

chain = [a, y, w, x, b]
chain.each_cons(2) do |first, second|
  edge = [first, second].sort
  unless edge_owners[edge] == 2
    raise "repaired chain edge is not two-owned: #{edge.inspect} -> #{edge_owners[edge]}"
  end
end

if edge_owners[[a, b].sort].positive?
  raise 'obsolete folded-sliver chord A-B survived repair'
end

puts 'LocalVertexNormalizer folded sliver strip smoke test: OK'
