# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry

        def self.add_sphere(entities, center, radius, segments: 16, rings: 8)
          validate_sphere_arguments!(entities, center, radius, segments, rings)

          points = sphere_points(center, radius, segments, rings)
          faces = []

          (0...rings).each do |ring_index|
            (0...segments).each do |segment_index|
              next_segment_index = (segment_index + 1) % segments
              face_points =
                if ring_index.zero?
                  [
                    points[ring_index][segment_index],
                    points[ring_index + 1][next_segment_index],
                    points[ring_index + 1][segment_index]
                  ]
                elsif ring_index == rings - 1
                  [
                    points[ring_index][segment_index],
                    points[ring_index][next_segment_index],
                    points[ring_index + 1][segment_index]
                  ]
                else
                  [
                    points[ring_index][segment_index],
                    points[ring_index][next_segment_index],
                    points[ring_index + 1][next_segment_index],
                    points[ring_index + 1][segment_index]
                  ]
                end

              face = entities.add_face(face_points)
              faces << face if face&.valid?
            end
          end

          faces
        end

        def self.add_cylinder(entities, radius, height, segments: 24)
          validate_cylinder_arguments!(entities, radius, height, segments)

          half_height = height / 2.0
          bottom_points = cylinder_ring_points(-half_height, radius, segments)
          top_points = cylinder_ring_points(half_height, radius, segments)
          faces = []

          bottom_face = entities.add_face(bottom_points.reverse)
          faces << bottom_face if bottom_face&.valid?

          top_face = entities.add_face(top_points)
          faces << top_face if top_face&.valid?

          (0...segments).each do |index|
            next_index = (index + 1) % segments
            face = entities.add_face(
              bottom_points[index],
              bottom_points[next_index],
              top_points[next_index],
              top_points[index]
            )
            faces << face if face&.valid?
          end

          faces
        end

        def self.adjacent_solids?(entity1, entity2, tolerance: 1.mm)
          !adjacency_axis(entity1, entity2, tolerance: tolerance).nil?
        end

        def self.horizontal_adjacency?(entity1, entity2, tolerance: 1.mm)
          axis = adjacency_axis(entity1, entity2, tolerance: tolerance)
          axis == :x || axis == :y
        end

        def self.vertical_adjacency?(entity1, entity2, tolerance: 1.mm)
          adjacency_axis(entity1, entity2, tolerance: tolerance) == :z
        end

        def self.adjacency_axis(entity1, entity2, tolerance: 1.mm)
          return nil unless entity1&.valid? && entity2&.valid?
          return nil unless touching_bounds?(entity1.bounds, entity2.bounds, tolerance)

          face_axis = adjacent_face_axis(entity1, entity2, tolerance)
          return face_axis unless face_axis.nil?

          touching_bounds_face_axis(entity1.bounds, entity2.bounds, tolerance)
        end

        def self.adjacency_snapshot(entity)
          return nil unless entity&.valid?
          return nil unless entity.respond_to?(:definition) && entity.respond_to?(:transformation)

          transformation = entity.transformation
          snapshot = {
            bounds: snapshot_bounds(entity.bounds),
            faces: snapshot_faces(entity, transformation)
          }
          deep_freeze(snapshot)
        end

        def self.adjacency_axis_from_snapshots(snapshot1, snapshot2, tolerance: 1.mm)
          return nil unless snapshot1 && snapshot2
          return nil unless touching_snapshot_bounds?(snapshot1[:bounds], snapshot2[:bounds], tolerance)

          face_axis = adjacent_snapshot_face_axis(snapshot1, snapshot2, tolerance)
          return face_axis unless face_axis.nil?

          touching_snapshot_bounds_face_axis(snapshot1[:bounds], snapshot2[:bounds], tolerance)
        end

        def self.common_face_waypoint_candidates(entity1, entity2, tolerance: 1.mm)
          return [] unless entity1&.valid? && entity2&.valid?
          return [] unless touching_bounds?(entity1.bounds, entity2.bounds, tolerance)

          candidates = common_face_candidates(entity1, entity2, tolerance)
          return [] if candidates.empty?

          max_area = candidates.map { |candidate| candidate[:area] }.max
          candidates.select { |candidate| (candidate[:area] - max_area).abs <= tolerance.to_f }
                    .map { |candidate| candidate[:centroid] }
        rescue StandardError => e
          puts "[IndoorGML] Common face waypoint candidates failed: #{e.class}: #{e.message}"
          []
        end

        def self.validate_cell_space_source_group(group)
          faces = group_faces(group)
          return { valid: false, reason: 'No faces found', component_count: 0, reversed_face_count: 0 } if faces.empty?

          components = face_components(faces)
          if components.length != 1
            return {
              valid: false,
              reason: "Disconnected solid shells detected (#{components.length} components)",
              component_count: components.length,
              reversed_face_count: 0
            }
          end

          {
            valid: true,
            reason: nil,
            component_count: 1,
            reversed_face_count: 0
          }
        end

        def self.prepare_cell_space_source_group!(group)
          result = validate_cell_space_source_group(group)
          return result unless result[:valid]

          result[:reversed_face_count] = orient_single_shell_faces!(group_faces(group))
          result
        end

        def self.sphere_points(center, radius, segments, rings)
          (0..rings).map do |ring_index|
            phi = Math::PI * ring_index / rings
            z = radius * Math.cos(phi)
            ring_radius = radius * Math.sin(phi)

            (0...segments).map do |segment_index|
              theta = 2.0 * Math::PI * segment_index / segments
              x = ring_radius * Math.cos(theta)
              y = ring_radius * Math.sin(theta)
              Geom::Point3d.new(center.x + x, center.y + y, center.z + z)
            end
          end
        end
        private_class_method :sphere_points

        def self.cylinder_ring_points(z, radius, segments)
          (0...segments).map do |segment_index|
            theta = 2.0 * Math::PI * segment_index / segments
            Geom::Point3d.new(
              radius * Math.cos(theta),
              radius * Math.sin(theta),
              z
            )
          end
        end
        private_class_method :cylinder_ring_points

        def self.world_faces(entity)
          transformation = entity.transformation
          entity.definition.entities.grep(Sketchup::Face).map do |face|
            points = face.outer_loop.vertices.map { |vertex| vertex.position.transform(transformation) }
            next if points.length < 3

            normal = face.normal.transform(transformation)
            normal.normalize!
            { points: points, normal: normal }
          end.compact
        end
        private_class_method :world_faces

        def self.common_face_candidates(entity1, entity2, tolerance)
          faces1 = world_faces(entity1)
          faces2 = world_faces(entity2)
          faces1.each_with_object([]) do |face1, candidates|
            faces2.each do |face2|
              next unless coplanar_touching_faces?(face1, face2, tolerance)

              overlap = coplanar_overlap_candidate(face1, face2, tolerance)
              candidates << overlap if overlap
            end
          end
        end
        private_class_method :common_face_candidates

        def self.coplanar_overlap_candidate(face1, face2, tolerance)
          axis = dominant_axis(face1[:normal])
          polygon1 = project_points_for_axis(face1[:points], axis)
          polygon2 = project_points_for_axis(face2[:points], axis)
          overlap = clip_polygon(polygon1, polygon2)
          return nil if overlap.length < 3

          area = polygon_area_2d(overlap).abs
          return nil if area <= tolerance.to_f

          centroid_2d = polygon_centroid_2d(overlap)
          centroid = unproject_point(centroid_2d, axis, face1[:normal], face1[:points].first)
          return nil unless centroid

          { area: area, centroid: centroid }
        end
        private_class_method :coplanar_overlap_candidate

        def self.project_points_for_axis(points, axis)
          points.map do |point|
            case axis
            when :x
              [point.y.to_f, point.z.to_f]
            when :y
              [point.x.to_f, point.z.to_f]
            else
              [point.x.to_f, point.y.to_f]
            end
          end
        end
        private_class_method :project_points_for_axis

        def self.snapshot_bounds(bounds)
          {
            min: [bounds.min.x.to_f, bounds.min.y.to_f, bounds.min.z.to_f],
            max: [bounds.max.x.to_f, bounds.max.y.to_f, bounds.max.z.to_f]
          }
        end
        private_class_method :snapshot_bounds

        def self.snapshot_faces(entity, transformation)
          entity.definition.entities.grep(Sketchup::Face).map do |face|
            points = face.outer_loop.vertices.map do |vertex|
              point = vertex.position.transform(transformation)
              [point.x.to_f, point.y.to_f, point.z.to_f]
            end
            next if points.length < 3

            normal = face.normal.transform(transformation)
            normal.normalize!
            { points: points, normal: [normal.x.to_f, normal.y.to_f, normal.z.to_f] }
          end.compact
        end
        private_class_method :snapshot_faces

        def self.group_faces(group)
          return [] unless group&.valid?
          return [] unless group.respond_to?(:definition) && group.definition&.valid?

          group.definition.entities.grep(Sketchup::Face).select(&:valid?)
        end
        private_class_method :group_faces

        def self.face_components(faces)
          remaining = faces.each_with_object({}) { |face, memo| memo[face] = true }
          components = []

          until remaining.empty?
            seed = remaining.keys.first
            component = []
            stack = [seed]
            remaining.delete(seed)

            until stack.empty?
              face = stack.pop
              component << face
              adjacent_faces(face).each do |neighbor|
                next unless remaining[neighbor]

                remaining.delete(neighbor)
                stack << neighbor
              end
            end

            components << component
          end

          components
        end
        private_class_method :face_components

        def self.adjacent_faces(face)
          face.edges.flat_map(&:faces).uniq.select { |candidate| candidate != face && candidate.valid? }
        end
        private_class_method :adjacent_faces

        def self.orient_single_shell_faces!(faces)
          desired_signs = propagated_face_orientation_signs(faces)
          return 0 if desired_signs.empty?

          signed_volume = shell_signed_volume(faces, desired_signs)
          if signed_volume.negative?
            desired_signs.transform_values! { |sign| -sign }
          end

          reversed_count = 0
          desired_signs.each do |face, sign|
            next unless sign == -1 && face.valid?

            face.reverse!
            reversed_count += 1
          end
          reversed_count
        end
        private_class_method :orient_single_shell_faces!

        def self.propagated_face_orientation_signs(faces)
          face_set = faces.each_with_object({}) { |face, memo| memo[face] = true }
          signs = {}

          faces.each do |seed|
            next if signs[seed]

            signs[seed] = 1
            stack = [seed]
            until stack.empty?
              face = stack.pop
              face.edges.each do |edge|
                edge.faces.each do |neighbor|
                  next if neighbor == face || !face_set[neighbor] || !neighbor.valid?

                  expected_sign = adjacent_face_orientation_sign(face, neighbor, edge, signs[face])
                  next if expected_sign.nil?

                  if signs[neighbor].nil?
                    signs[neighbor] = expected_sign
                    stack << neighbor
                  end
                end
              end
            end
          end

          signs
        end
        private_class_method :propagated_face_orientation_signs

        def self.adjacent_face_orientation_sign(face, neighbor, edge, face_sign)
          face_direction = face_edge_direction(face, edge)
          neighbor_direction = face_edge_direction(neighbor, edge)
          return nil if face_direction.nil? || neighbor_direction.nil?

          -face_sign * face_direction * neighbor_direction
        end
        private_class_method :adjacent_face_orientation_sign

        def self.face_edge_direction(face, edge)
          edge_vertices = edge.vertices
          return nil unless edge_vertices.length == 2

          face.loops.each do |loop|
            vertices = loop.vertices
            vertices.each_index do |index|
              current_vertex = vertices[index]
              next_vertex = vertices[(index + 1) % vertices.length]
              return 1 if current_vertex == edge_vertices[0] && next_vertex == edge_vertices[1]
              return -1 if current_vertex == edge_vertices[1] && next_vertex == edge_vertices[0]
            end
          end

          nil
        end
        private_class_method :face_edge_direction

        def self.shell_signed_volume(faces, signs)
          faces.sum do |face|
            sign = signs[face] || 1
            sign * face_signed_volume(face)
          end
        end
        private_class_method :shell_signed_volume

        def self.face_signed_volume(face)
          points = face.outer_loop.vertices.map(&:position)
          return 0.0 if points.length < 3

          origin = points.first
          volume = 0.0
          (1...(points.length - 1)).each do |index|
            volume += signed_tetrahedron_volume(origin, points[index], points[index + 1])
          end
          volume
        end
        private_class_method :face_signed_volume

        def self.signed_tetrahedron_volume(point1, point2, point3)
          (
            (point1.x * ((point2.y * point3.z) - (point2.z * point3.y))) -
            (point1.y * ((point2.x * point3.z) - (point2.z * point3.x))) +
            (point1.z * ((point2.x * point3.y) - (point2.y * point3.x)))
          ) / 6.0
        end
        private_class_method :signed_tetrahedron_volume

        def self.deep_freeze(object)
          case object
          when Array
            object.each { |item| deep_freeze(item) }
          when Hash
            object.each_value { |value| deep_freeze(value) }
          end
          object.freeze
        end
        private_class_method :deep_freeze

        def self.adjacent_face_axis(entity1, entity2, tolerance)
          faces1 = world_faces(entity1)
          faces2 = world_faces(entity2)
          return nil if faces1.empty? || faces2.empty?

          faces1.each do |face1|
            faces2.each do |face2|
              next unless coplanar_touching_faces?(face1, face2, tolerance)

              return dominant_axis(face1[:normal])
            end
          end

          nil
        end
        private_class_method :adjacent_face_axis

        def self.touching_bounds?(bounds1, bounds2, tolerance)
          axis_overlap_or_touch?(bounds1.min.x, bounds1.max.x, bounds2.min.x, bounds2.max.x, tolerance) &&
            axis_overlap_or_touch?(bounds1.min.y, bounds1.max.y, bounds2.min.y, bounds2.max.y, tolerance) &&
            axis_overlap_or_touch?(bounds1.min.z, bounds1.max.z, bounds2.min.z, bounds2.max.z, tolerance)
        end
        private_class_method :touching_bounds?

        def self.touching_snapshot_bounds?(bounds1, bounds2, tolerance)
          axis_overlap_or_touch?(bounds1[:min][0], bounds1[:max][0], bounds2[:min][0], bounds2[:max][0], tolerance) &&
            axis_overlap_or_touch?(bounds1[:min][1], bounds1[:max][1], bounds2[:min][1], bounds2[:max][1], tolerance) &&
            axis_overlap_or_touch?(bounds1[:min][2], bounds1[:max][2], bounds2[:min][2], bounds2[:max][2], tolerance)
        end
        private_class_method :touching_snapshot_bounds?

        def self.touching_bounds_face_axis(bounds1, bounds2, tolerance)
          [:x, :y, :z].find do |axis|
            bounds_face_contact_on_axis?(bounds1, bounds2, axis, tolerance)
          end
        end
        private_class_method :touching_bounds_face_axis

        def self.touching_snapshot_bounds_face_axis(bounds1, bounds2, tolerance)
          [0, 1, 2].each do |axis|
            return axis_symbol(axis) if snapshot_bounds_face_contact_on_axis?(bounds1, bounds2, axis, tolerance)
          end
          nil
        end
        private_class_method :touching_snapshot_bounds_face_axis

        def self.bounds_face_contact_on_axis?(bounds1, bounds2, axis, tolerance)
          min1 = bounds1.min.public_send(axis)
          max1 = bounds1.max.public_send(axis)
          min2 = bounds2.min.public_send(axis)
          max2 = bounds2.max.public_send(axis)
          return false unless (max1 - min2).abs <= tolerance || (max2 - min1).abs <= tolerance

          axes = [:x, :y, :z] - [axis]
          axes.all? do |overlap_axis|
            overlap_length(
              bounds1.min.public_send(overlap_axis),
              bounds1.max.public_send(overlap_axis),
              bounds2.min.public_send(overlap_axis),
              bounds2.max.public_send(overlap_axis)
            ) > tolerance
          end
        end
        private_class_method :bounds_face_contact_on_axis?

        def self.snapshot_bounds_face_contact_on_axis?(bounds1, bounds2, axis, tolerance)
          min1 = bounds1[:min][axis]
          max1 = bounds1[:max][axis]
          min2 = bounds2[:min][axis]
          max2 = bounds2[:max][axis]
          return false unless (max1 - min2).abs <= tolerance || (max2 - min1).abs <= tolerance

          ([0, 1, 2] - [axis]).all? do |overlap_axis|
            overlap_length(
              bounds1[:min][overlap_axis],
              bounds1[:max][overlap_axis],
              bounds2[:min][overlap_axis],
              bounds2[:max][overlap_axis]
            ) > tolerance
          end
        end
        private_class_method :snapshot_bounds_face_contact_on_axis?

        def self.dominant_axis(vector)
          values = { x: vector.x.abs, y: vector.y.abs, z: vector.z.abs }
          values.max_by { |_axis, value| value }.first
        end
        private_class_method :dominant_axis

        def self.dominant_snapshot_axis(vector)
          values = { x: vector[0].abs, y: vector[1].abs, z: vector[2].abs }
          values.max_by { |_axis, value| value }.first
        end
        private_class_method :dominant_snapshot_axis

        def self.axis_symbol(axis)
          [:x, :y, :z][axis]
        end
        private_class_method :axis_symbol

        def self.axis_overlap_or_touch?(min1, max1, min2, max2, tolerance)
          [min1, min2].max <= [max1, max2].min + tolerance
        end
        private_class_method :axis_overlap_or_touch?

        def self.overlap_length(min1, max1, min2, max2)
          [max1, max2].min - [min1, min2].max
        end
        private_class_method :overlap_length

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

        def self.unproject_point(point_2d, axis, normal, plane_point)
          plane_dot = dot_product(Geom::Vector3d.new(plane_point.x, plane_point.y, plane_point.z), normal)
          case axis
          when :x
            return nil if normal.x.abs <= 0.000001

            y, z = point_2d
            x = (plane_dot - (normal.y * y) - (normal.z * z)) / normal.x
            Geom::Point3d.new(x, y, z)
          when :y
            return nil if normal.y.abs <= 0.000001

            x, z = point_2d
            y = (plane_dot - (normal.x * x) - (normal.z * z)) / normal.y
            Geom::Point3d.new(x, y, z)
          else
            return nil if normal.z.abs <= 0.000001

            x, y = point_2d
            z = (plane_dot - (normal.x * x) - (normal.y * y)) / normal.z
            Geom::Point3d.new(x, y, z)
          end
        end
        private_class_method :unproject_point

        def self.coplanar_touching_faces?(face1, face2, tolerance)
          normal1 = face1[:normal]
          normal2 = face2[:normal]
          return false unless normals_parallel?(normal1, normal2)
          return false unless points_on_plane?(face2[:points], normal1, face1[:points].first, tolerance)

          polygon1 = project_points(face1[:points], normal1)
          polygon2 = project_points(face2[:points], normal1)
          polygons_touch?(polygon1, polygon2, tolerance)
        end
        private_class_method :coplanar_touching_faces?

        def self.adjacent_snapshot_face_axis(snapshot1, snapshot2, tolerance)
          faces1 = snapshot1[:faces]
          faces2 = snapshot2[:faces]
          return nil if faces1.empty? || faces2.empty?

          faces1.each do |face1|
            faces2.each do |face2|
              next unless coplanar_touching_snapshot_faces?(face1, face2, tolerance)

              return dominant_snapshot_axis(face1[:normal])
            end
          end

          nil
        end
        private_class_method :adjacent_snapshot_face_axis

        def self.coplanar_touching_snapshot_faces?(face1, face2, tolerance)
          normal1 = face1[:normal]
          normal2 = face2[:normal]
          return false unless snapshot_normals_parallel?(normal1, normal2)
          return false unless snapshot_points_on_plane?(face2[:points], normal1, face1[:points].first, tolerance)

          polygon1 = project_snapshot_points(face1[:points], normal1)
          polygon2 = project_snapshot_points(face2[:points], normal1)
          polygons_touch?(polygon1, polygon2, tolerance)
        end
        private_class_method :coplanar_touching_snapshot_faces?

        def self.normals_parallel?(normal1, normal2)
          dot = dot_product(normal1, normal2).abs
          (1.0 - dot) <= 0.000001
        end
        private_class_method :normals_parallel?

        def self.snapshot_normals_parallel?(normal1, normal2)
          dot = snapshot_dot_product(normal1, normal2).abs
          (1.0 - dot) <= 0.000001
        end
        private_class_method :snapshot_normals_parallel?

        def self.points_on_plane?(points, normal, plane_point, tolerance)
          points.all? do |point|
            vector = plane_point.vector_to(point)
            dot_product(vector, normal).abs <= tolerance
          end
        end
        private_class_method :points_on_plane?

        def self.snapshot_points_on_plane?(points, normal, plane_point, tolerance)
          points.all? do |point|
            vector = [
              point[0] - plane_point[0],
              point[1] - plane_point[1],
              point[2] - plane_point[2]
            ]
            snapshot_dot_product(vector, normal).abs <= tolerance
          end
        end
        private_class_method :snapshot_points_on_plane?

        def self.project_points(points, normal)
          ax = normal.x.abs
          ay = normal.y.abs
          az = normal.z.abs

          points.map do |point|
            if ax >= ay && ax >= az
              [point.y.to_f, point.z.to_f]
            elsif ay >= ax && ay >= az
              [point.x.to_f, point.z.to_f]
            else
              [point.x.to_f, point.y.to_f]
            end
          end
        end
        private_class_method :project_points

        def self.project_snapshot_points(points, normal)
          ax = normal[0].abs
          ay = normal[1].abs
          az = normal[2].abs

          points.map do |point|
            if ax >= ay && ax >= az
              [point[1], point[2]]
            elsif ay >= ax && ay >= az
              [point[0], point[2]]
            else
              [point[0], point[1]]
            end
          end
        end
        private_class_method :project_snapshot_points

        def self.polygons_touch?(polygon1, polygon2, tolerance)
          polygon1.any? { |point| point_in_polygon?(point, polygon2, tolerance) } ||
            polygon2.any? { |point| point_in_polygon?(point, polygon1, tolerance) } ||
            polygon_edges(polygon1).any? do |edge1|
              polygon_edges(polygon2).any? { |edge2| segments_intersect?(edge1, edge2, tolerance) }
            end
        end
        private_class_method :polygons_touch?

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

        def self.segments_intersect?(edge1, edge2, tolerance)
          p1, p2 = edge1
          q1, q2 = edge2

          return true if point_on_segment?(p1, edge2, tolerance)
          return true if point_on_segment?(p2, edge2, tolerance)
          return true if point_on_segment?(q1, edge1, tolerance)
          return true if point_on_segment?(q2, edge1, tolerance)

          orientation(p1, p2, q1) * orientation(p1, p2, q2) < 0 &&
            orientation(q1, q2, p1) * orientation(q1, q2, p2) < 0
        end
        private_class_method :segments_intersect?

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

        def self.dot_product(vector1, vector2)
          (vector1.x * vector2.x) + (vector1.y * vector2.y) + (vector1.z * vector2.z)
        end
        private_class_method :dot_product

        def self.snapshot_dot_product(vector1, vector2)
          (vector1[0] * vector2[0]) + (vector1[1] * vector2[1]) + (vector1[2] * vector2[2])
        end
        private_class_method :snapshot_dot_product

        def self.validate_sphere_arguments!(entities, center, radius, segments, rings)
          unless entities.respond_to?(:add_face)
            raise ArgumentError, 'Sketchup::Entities expected'
          end

          unless center.is_a?(Geom::Point3d)
            raise ArgumentError, 'Geom::Point3d center expected'
          end

          raise ArgumentError, 'Positive radius expected' unless radius.positive?
          raise ArgumentError, 'segments must be at least 8' if segments < 8
          raise ArgumentError, 'rings must be at least 4' if rings < 4
        end
        private_class_method :validate_sphere_arguments!

        def self.validate_cylinder_arguments!(entities, radius, height, segments)
          unless entities.respond_to?(:add_face)
            raise ArgumentError, 'Sketchup::Entities expected'
          end

          raise ArgumentError, 'Positive radius expected' unless radius.positive?
          raise ArgumentError, 'Positive height expected' unless height.positive?
          raise ArgumentError, 'segments must be at least 8' if segments < 8
        end
        private_class_method :validate_cylinder_arguments!

      end
    end
  end
end
