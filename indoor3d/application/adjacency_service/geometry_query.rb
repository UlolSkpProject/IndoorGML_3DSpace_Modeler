# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AdjacencyService
        module GeometryQuery
          def self.common_face_waypoint_candidates(entity1, entity2, state1_point: nil, state2_point: nil, tolerance: Utils::Geometry::DEFAULT_TOLERANCE)
            return [] unless entity1&.valid? && entity2&.valid?
            return [] unless Utils::Geometry.touching_bounds?(entity1.bounds, entity2.bounds, tolerance)

            candidates = common_face_candidates(entity1, entity2, tolerance)
            return [] if candidates.empty?

            max_area = candidates.map { |candidate| candidate[:area] }.max
            candidates.select { |candidate| (candidate[:area] - max_area).abs <= tolerance.to_f }
                      .map do |candidate|
                        {
                          point: adjusted_waypoint(candidate, state1_point, state2_point, tolerance),
                          normal1: candidate[:normal1],
                          normal2: candidate[:normal2]
                        }
                      end
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Common face waypoint candidates failed: #{e.class}: #{e.message}"
            []
          end

          def self.common_face_candidates(entity1, entity2, tolerance)
            faces1 = Utils::Geometry.world_faces(entity1)
            faces2 = Utils::Geometry.world_faces(entity2)
            faces1.each_with_object([]) do |face1, candidates|
              faces2.each do |face2|
                next unless Utils::Geometry.normals_opposite?(face1[:normal], face2[:normal])
                next unless Utils::Geometry.points_on_plane?(face2[:points], face1[:normal], face1[:points].first, tolerance)

                overlap = coplanar_overlap_candidate(face1, face2, tolerance)
                candidates << overlap if overlap
              end
            end
          end

          def self.coplanar_overlap_candidate(face1, face2, tolerance)
            metrics = Utils::Geometry.coplanar_overlap_metrics(face1, face2, tolerance)
            return nil unless metrics

            area = metrics[:area]
            centroid_2d = metrics[:centroid_2d]
            axis = Utils::Geometry.dominant_axis(face1[:normal])
            centroid = unproject_point(centroid_2d, axis, face1[:normal], face1[:points].first)
            return nil unless centroid

            { area: area, centroid: centroid, normal1: face1[:normal], normal2: face2[:normal], face1: face1, face2: face2 }
          end
          private_class_method :coplanar_overlap_candidate

          def self.adjusted_waypoint(candidate, state1_point, state2_point, tolerance)
            centroid = candidate[:centroid]
            return centroid unless centroid.is_a?(Geom::Point3d)
            return centroid unless state1_point.is_a?(Geom::Point3d) && state2_point.is_a?(Geom::Point3d)

            face1 = candidate[:face1]
            face2 = candidate[:face2]
            normal = candidate[:normal1]
            return centroid unless face1 && face2 && normal.is_a?(Geom::Vector3d)

            axis = Utils::Geometry.dominant_axis(normal)
            return centroid if axis == :z

            z_min, z_max = shared_z_range(face1, face2)
            return centroid unless z_min && z_max && z_min <= z_max

            z1 = clamp(state1_point.z, z_min, z_max)
            z2 = clamp(state2_point.z, z_min, z_max)
            adjusted_z = if (z1 - z2).abs <= tolerance.to_f
                           z1
                         else
                           ratio = midpoint_distance_ratio(state1_point, state2_point, centroid)
                           z1 + ((z2 - z1) * ratio)
                         end
            adjusted = unproject_point_with_z(centroid, adjusted_z, axis, normal, face1[:points].first)
            return centroid unless adjusted
            return centroid unless point_in_face?(adjusted, face1, axis, tolerance)
            return centroid unless point_in_face?(adjusted, face2, axis, tolerance)

            adjusted
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Waypoint z adjustment failed: #{e.class}: #{e.message}"
            candidate[:centroid]
          end
          private_class_method :adjusted_waypoint

          def self.shared_z_range(face1, face2)
            ranges = [face1, face2].map do |face|
              points = Array(face[:points])
              next nil if points.empty?

              points.map(&:z).minmax
            end.compact
            return nil if ranges.length < 2

            [[ranges[0][0], ranges[1][0]].max, [ranges[0][1], ranges[1][1]].min]
          end
          private_class_method :shared_z_range

          def self.midpoint_distance_ratio(point1, point2, midpoint)
            distance1 = point1.distance(midpoint)
            distance2 = point2.distance(midpoint)
            total = distance1 + distance2
            return 0.5 if total <= 0.000001

            clamp(distance1 / total, 0.0, 1.0)
          end
          private_class_method :midpoint_distance_ratio

          def self.unproject_point_with_z(reference_point, z, axis, normal, plane_point)
            plane_dot = Utils::Geometry.dot_product(
              Geom::Vector3d.new(plane_point.x, plane_point.y, plane_point.z),
              normal
            )
            case axis
            when :x
              return nil if normal.x.abs <= 0.000001

              y = reference_point.y
              x = (plane_dot - (normal.y * y) - (normal.z * z)) / normal.x
              Geom::Point3d.new(x, y, z)
            when :y
              return nil if normal.y.abs <= 0.000001

              x = reference_point.x
              y = (plane_dot - (normal.x * x) - (normal.z * z)) / normal.y
              Geom::Point3d.new(x, y, z)
            else
              reference_point
            end
          end
          private_class_method :unproject_point_with_z

          def self.point_in_face?(point, face, axis, tolerance)
            polygon = Utils::Geometry.project_points_for_axis(face[:points], axis)
            point_2d = Utils::Geometry.project_points_for_axis([point], axis).first
            Utils::Geometry.send(:point_in_polygon?, point_2d, polygon, tolerance)
          end
          private_class_method :point_in_face?

          def self.clamp(value, min, max)
            [[value.to_f, min.to_f].max, max.to_f].min
          end
          private_class_method :clamp

          def self.unproject_point(point_2d, axis, normal, plane_point)
            plane_dot = Utils::Geometry.dot_product(
              Geom::Vector3d.new(plane_point.x, plane_point.y, plane_point.z),
              normal
            )
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
        end
      end
    end
  end
end
