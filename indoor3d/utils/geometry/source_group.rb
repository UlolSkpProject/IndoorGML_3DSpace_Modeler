# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
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
      end
    end
  end
end
