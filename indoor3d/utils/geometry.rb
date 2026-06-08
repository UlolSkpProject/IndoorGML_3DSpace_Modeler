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
