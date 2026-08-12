# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        # CellSpace geometry is rendered with explicit solid edges regardless of
        # the source group's hidden/soft/smooth edge styling. The group has
        # already been isolated by the creation workflow before this runs, so
        # changing these flags does not affect a shared source definition.
        def self.make_cell_space_edges_solid!(group)
          return 0 unless group&.respond_to?(:definition)

          definition = group.definition
          return 0 unless definition&.respond_to?(:valid?) && definition.valid?
          return 0 unless definition.respond_to?(:entities)

          changed_count = 0
          definition.entities.grep(Sketchup::Edge).each do |edge|
            next unless edge&.valid?

            changed = false
            if edge.hidden?
              edge.hidden = false
              changed = true
            end
            if edge.soft?
              edge.soft = false
              changed = true
            end
            if edge.smooth?
              edge.smooth = false
              changed = true
            end
            changed_count += 1 if changed
          end
          changed_count
        end

        def self.validate_cell_space_source_group(group)
          faces = group_faces(group)
          return { valid: false, reason: 'No faces found', component_count: 0, reversed_face_count: 0 } if faces.empty?

          components = face_components(faces)
          classification = classify_shell_components(components)
          unless classification[:valid]
            return {
              valid: false,
              reason: classification[:reason],
              component_count: components.length,
              reversed_face_count: 0
            }
          end

          {
            valid: true,
            reason: nil,
            component_count: components.length,
            exterior_faces: classification[:exterior_faces],
            interior_face_components: classification[:interior_face_components],
            reversed_face_count: 0
          }
        end

        def self.prepare_cell_space_source_group!(group)
          result = validate_cell_space_source_group(group)
          return result unless result[:valid]

          reversed_count = orient_shell_faces!(result[:exterior_faces], positive_volume: true)
          Array(result[:interior_face_components]).each do |faces|
            reversed_count += orient_shell_faces!(faces, positive_volume: false)
          end
          result[:reversed_face_count] = reversed_count
          result
        end

        def self.classify_shell_components(components)
          components = Array(components).reject(&:empty?)
          return { valid: false, reason: 'No closed shell components found' } if components.empty?
          return {
            valid: true,
            exterior_faces: components.first,
            interior_face_components: []
          } if components.length == 1

          unless respond_to?(:shell_contains_point_in_faces?)
            return {
              valid: false,
              reason: "Disconnected solid shells detected (#{components.length} components)"
            }
          end

          nesting_depths = components.map.with_index do |component, index|
            point = component_representative_point(component)
            return { valid: false, reason: 'Unable to classify solid shell containment' } unless point

            components.each_with_index.count do |candidate, candidate_index|
              candidate_index != index && shell_contains_point_in_faces?(candidate, point)
            end
          end
          exterior_indices = nesting_depths.each_index.select { |index| nesting_depths[index].zero? }
          interior_indices = nesting_depths.each_index.select { |index| nesting_depths[index] == 1 }
          valid = exterior_indices.length == 1 &&
                  interior_indices.length == components.length - 1 &&
                  interior_indices.all? do |index|
                    shell_contains_point_in_faces?(
                      components[exterior_indices.first],
                      component_representative_point(components[index])
                    )
                  end
          unless valid
            return {
              valid: false,
              reason: "Disconnected or nested solid shells detected (#{components.length} components)"
            }
          end

          {
            valid: true,
            exterior_faces: components[exterior_indices.first],
            interior_face_components: interior_indices.map { |index| components[index] }
          }
        end
        private_class_method :classify_shell_components

        def self.component_representative_point(faces)
          face = Array(faces).find { |candidate| candidate&.valid? }
          face&.outer_loop&.vertices&.first&.position
        rescue StandardError
          nil
        end
        private_class_method :component_representative_point
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

        def self.orient_shell_faces!(faces, positive_volume:)
          desired_signs = propagated_face_orientation_signs(faces)
          return 0 if desired_signs.empty?

          signed_volume = shell_signed_volume(faces, desired_signs)
          should_reverse = positive_volume ? signed_volume.negative? : signed_volume.positive?
          if should_reverse
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
        private_class_method :orient_shell_faces!

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
