# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        def self.adjacency_axis(entity1, entity2, tolerance: 1.mm)
          return nil unless entity1&.valid? && entity2&.valid?
          return nil unless touching_bounds?(entity1.bounds, entity2.bounds, tolerance)

          adjacent_face_axis(entity1, entity2, tolerance)
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

          adjacent_snapshot_face_axis(snapshot1, snapshot2, tolerance)
        end
        def self.world_faces(entity)
          transformation = entity.transformation
          entity.definition.entities.grep(Sketchup::Face).map do |face|
            points = face.outer_loop.vertices.map { |vertex| vertex.position.transform(transformation) }
            next if points.length < 3

            normal = face.normal.transform(transformation)
            normal.normalize!
            { points: points, normal: normal, triangles: face_mesh_triangles(face, transformation) }
          end.compact
        end

        def self.coplanar_overlap_metrics(face1, face2, tolerance)
          return nil if face1[:triangles].empty? || face2[:triangles].empty?

          axis = dominant_axis(face1[:normal])
          weighted_x = 0.0
          weighted_y = 0.0
          total_area = 0.0

          face1[:triangles].each do |triangle1|
            polygon1 = project_points_for_axis(triangle1, axis)
            face2[:triangles].each do |triangle2|
              polygon2 = project_points_for_axis(triangle2, axis)
              overlap = clip_polygon(polygon1, polygon2)
              next if overlap.length < 3

              area = polygon_area_2d(overlap).abs
              next if area <= area_tolerance(tolerance)

              centroid = polygon_centroid_2d(overlap)
              weighted_x += centroid[0] * area
              weighted_y += centroid[1] * area
              total_area += area
            end
          end
          return nil if total_area <= area_tolerance(tolerance)

          { area: total_area, centroid_2d: [weighted_x / total_area, weighted_y / total_area] }
        end

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
            triangles = face_mesh_triangles(face, transformation).map do |triangle|
              triangle.map { |point| [point.x.to_f, point.y.to_f, point.z.to_f] }
            end
            { points: points, normal: [normal.x.to_f, normal.y.to_f, normal.z.to_f], triangles: triangles }
          end.compact
        end
        private_class_method :snapshot_faces

        def self.face_mesh_triangles(face, transformation)
          mesh = face.mesh
          points = (1..mesh.count_points).map { |index| mesh.point_at(index).transform(transformation) }
          (1..mesh.count_polygons).flat_map do |index|
            polygon = mesh.polygon_at(index).map { |point_index| points[point_index.abs - 1] }.compact
            next [] if polygon.length < 3

            polygon.length == 3 ? [polygon] : triangulate_polygon_fan(polygon)
          end
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Face mesh triangulation failed: #{e.class}: #{e.message}"
          []
        end
        private_class_method :face_mesh_triangles

        def self.triangulate_polygon_fan(points)
          (1...(points.length - 1)).map { |index| [points.first, points[index], points[index + 1]] }
        end
        private_class_method :triangulate_polygon_fan
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
              next unless coplanar_area_overlapping_faces?(face1, face2, tolerance)

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

        def self.touching_snapshot_bounds?(bounds1, bounds2, tolerance)
          axis_overlap_or_touch?(bounds1[:min][0], bounds1[:max][0], bounds2[:min][0], bounds2[:max][0], tolerance) &&
            axis_overlap_or_touch?(bounds1[:min][1], bounds1[:max][1], bounds2[:min][1], bounds2[:max][1], tolerance) &&
            axis_overlap_or_touch?(bounds1[:min][2], bounds1[:max][2], bounds2[:min][2], bounds2[:max][2], tolerance)
        end
        private_class_method :touching_snapshot_bounds?

        def self.dominant_axis(vector)
          values = { x: vector.x.abs, y: vector.y.abs, z: vector.z.abs }
          values.max_by { |_axis, value| value }.first
        end

        def self.dominant_snapshot_axis(vector)
          values = { x: vector[0].abs, y: vector[1].abs, z: vector[2].abs }
          values.max_by { |_axis, value| value }.first
        end
        private_class_method :dominant_snapshot_axis

        def self.axis_overlap_or_touch?(min1, max1, min2, max2, tolerance)
          [min1, min2].max <= [max1, max2].min + tolerance
        end
        private_class_method :axis_overlap_or_touch?
        def self.coplanar_area_overlapping_faces?(face1, face2, tolerance)
          normal1 = face1[:normal]
          normal2 = face2[:normal]
          return false unless normals_parallel?(normal1, normal2)
          return false unless points_on_plane?(face2[:points], normal1, face1[:points].first, tolerance)

          metrics = coplanar_overlap_metrics(face1, face2, tolerance)
          metrics && metrics[:area] > area_tolerance(tolerance)
        end
        private_class_method :coplanar_area_overlapping_faces?

        def self.adjacent_snapshot_face_axis(snapshot1, snapshot2, tolerance)
          faces1 = snapshot1[:faces]
          faces2 = snapshot2[:faces]
          return nil if faces1.empty? || faces2.empty?

          faces1.each do |face1|
            faces2.each do |face2|
              next unless coplanar_area_overlapping_snapshot_faces?(face1, face2, tolerance)

              return dominant_snapshot_axis(face1[:normal])
            end
          end

          nil
        end
        private_class_method :adjacent_snapshot_face_axis

        def self.coplanar_area_overlapping_snapshot_faces?(face1, face2, tolerance)
          normal1 = face1[:normal]
          normal2 = face2[:normal]
          return false unless snapshot_normals_parallel?(normal1, normal2)
          return false unless snapshot_points_on_plane?(face2[:points], normal1, face1[:points].first, tolerance)

          snapshot_coplanar_overlap_area(face1, face2) > area_tolerance(tolerance)
        end
        private_class_method :coplanar_area_overlapping_snapshot_faces?

        def self.snapshot_coplanar_overlap_area(face1, face2)
          return 0.0 if face1[:triangles].empty? || face2[:triangles].empty?

          axis = dominant_snapshot_axis(face1[:normal])
          face1[:triangles].sum do |triangle1|
            polygon1 = project_snapshot_points_for_axis(triangle1, axis)
            face2[:triangles].sum do |triangle2|
              polygon2 = project_snapshot_points_for_axis(triangle2, axis)
              polygon_area_2d(clip_polygon(polygon1, polygon2)).abs
            end
          end
        end
        private_class_method :snapshot_coplanar_overlap_area

        def self.area_tolerance(tolerance)
          tolerance.to_f * tolerance.to_f
        end

        def self.normals_parallel?(normal1, normal2)
          dot = dot_product(normal1, normal2).abs
          (1.0 - dot) <= 0.000001
        end

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

        def self.project_snapshot_points_for_axis(points, axis)
          points.map do |point|
            case axis
            when :x
              [point[1], point[2]]
            when :y
              [point[0], point[2]]
            else
              [point[0], point[1]]
            end
          end
        end
        private_class_method :project_snapshot_points_for_axis
        def self.dot_product(vector1, vector2)
          (vector1.x * vector2.x) + (vector1.y * vector2.y) + (vector1.z * vector2.z)
        end

        def self.snapshot_dot_product(vector1, vector2)
          (vector1[0] * vector2[0]) + (vector1[1] * vector2[1]) + (vector1[2] * vector2[2])
        end
        private_class_method :snapshot_dot_product
      end
    end
  end
end
