# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AdjacencyService
        module GeometryQuery
          def self.common_face_waypoint_candidates(entity1, entity2, tolerance: 1.mm)
            return [] unless entity1&.valid? && entity2&.valid?
            return [] unless Utils::Geometry.touching_bounds?(entity1.bounds, entity2.bounds, tolerance)

            candidates = common_face_candidates(entity1, entity2, tolerance)
            return [] if candidates.empty?

            max_area = candidates.map { |candidate| candidate[:area] }.max
            candidates.select { |candidate| (candidate[:area] - max_area).abs <= tolerance.to_f }
                      .map do |candidate|
                        {
                          point: candidate[:centroid],
                          normal1: candidate[:normal1],
                          normal2: candidate[:normal2]
                        }
                      end
          rescue StandardError => e
            puts "[IndoorGML] Common face waypoint candidates failed: #{e.class}: #{e.message}"
            []
          end

          def self.common_face_candidates(entity1, entity2, tolerance)
            faces1 = Utils::Geometry.world_faces(entity1)
            faces2 = Utils::Geometry.world_faces(entity2)
            faces1.each_with_object([]) do |face1, candidates|
              faces2.each do |face2|
                next unless Utils::Geometry.normals_parallel?(face1[:normal], face2[:normal])
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

            { area: area, centroid: centroid, normal1: face1[:normal], normal2: face2[:normal] }
          end
          private_class_method :coplanar_overlap_candidate

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
