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

      end
    end
  end
end
