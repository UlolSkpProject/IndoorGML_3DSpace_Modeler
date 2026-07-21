# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # ----------------------------------------------------------------------
        # Grid projection and triangle snapshots
        # ----------------------------------------------------------------------

        # Builds exact local X/Y/Z plane constraints before ordinary grid
        # projection. Only faces connected through an actual shared edge
        # participate in the same family. Coordinate distance is deliberately
        # not a grouping condition: adjacent subdivisions of one intended plane
        # are unified, while disconnected parallel planes such as a floor and a
        # ceiling remain independent.

        def axis_plane_face_record(face)
          return nil unless face&.valid?

          axis = axis_aligned_normal_axis(face.normal)
          return nil if axis.nil?

          vertices = face.vertices
          return nil if vertices.length < 3

          coordinates_mm = vertices.map do |vertex|
            point_coordinate(vertex.position, axis) * MM_PER_INCH
          end

          {
            face: face,
            axis: axis,
            vertices: vertices,
            vertex_ids: vertices.map { |vertex| stable_entity_id(vertex) },
            edge_ids: face.edges.map { |edge| stable_entity_id(edge) },
            coordinates_mm: coordinates_mm
          }
        rescue StandardError
          nil
        end

        def axis_aligned_normal_axis(normal)
          components = vector_components(normal)
          length = vector_length(components)
          return nil if length <= 0.0

          normalized = components.map { |value| value / length }
          axis = normalized.each_index.max_by { |index| normalized[index].abs }
          cosine = normalized[axis].abs
          threshold = Math.cos(AXIS_PLANE_ANGLE_TOLERANCE_DEG * Math::PI / 180.0)
          cosine + 1.0e-15 >= threshold ? axis : nil
        rescue StandardError
          nil
        end

        def axis_plane_connected_components(records)
          by_edge = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, index|
            record[:edge_ids].each { |edge_id| by_edge[edge_id] << index }
          end

          visited = Array.new(records.length, false)
          records.each_index.filter_map do |seed|
            next if visited[seed]

            visited[seed] = true
            queue = [seed]
            component = []
            until queue.empty?
              index = queue.shift
              record = records[index]
              component << record
              record[:edge_ids].each do |edge_id|
                by_edge[edge_id].each do |neighbor|
                  next if visited[neighbor]

                  visited[neighbor] = true
                  queue << neighbor
                end
              end
            end
            component
          end
        end

        # Removes only the internal edges of rebuilt local-axis plane
        # families. Plane equality is exact on the integer normalization grid;
        # no distance tolerance is used here. Disconnected parallel surfaces
        # never become candidates because there is no shared edge to erase.

        def median_value(values)
          sorted = Array(values).map(&:to_f).sort
          raise ReconstructionError, 'Axis-plane family has no coordinates' if sorted.empty?

          middle = sorted.length / 2
          return sorted[middle] if sorted.length.odd?

          (sorted[middle - 1] + sorted[middle]) / 2.0
        end
      end
    end
  end
end
