# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # ----------------------------------------------------------------------
        # Rebuild and surface repair
        # ----------------------------------------------------------------------

        def erase_source_geometry(entities)
          geometry = entities.to_a.select do |item|
            item.is_a?(@face_class) || item.is_a?(@edge_class)
          end
          entities.erase_entities(geometry) unless geometry.empty?
        end

        def rebuild_triangles(entities, triangles)
          if entities.respond_to?(:fill_from_mesh) &&
             defined?(Geom::PolygonMesh)
            return rebuild_triangles_from_mesh(entities, triangles)
          end

          added_faces = 0
          skipped_collinear = 0

          triangles.each do |record|
            points = record[:points]
            if collinear_triangle?(points)
              skipped_collinear += 1
              next
            end

            face = entities.add_face(points)
            unless face&.valid?
              raise ReconstructionError,
                    "add_face failed for normalized triangle " \
                    "#{points.map { |point| point_components_mm(point) }.inspect}"
            end

            orient_face!(face, record[:source_normal])
            apply_face_metadata(face, record)
            added_faces += 1
          end

          { added_faces: added_faces, skipped_collinear: skipped_collinear }
        end

        # Sequential add_face calls allow SketchUp to auto-heal intermediate
        # closed loops into hole/cap faces before the remaining triangles are
        # added. Bulk mesh filling creates the already-validated complex in one
        # step and therefore preserves its exact edge incidence.
        def rebuild_triangles_from_mesh(entities, triangles)
          polygon_mesh = Geom::PolygonMesh.new
          point_indices = {}
          records_by_signature = {}

          triangles.each do |record|
            points = record[:points]
            if collinear_triangle?(points)
              raise ReconstructionError,
                    "Validated triangle became collinear before mesh fill: " \
                    "#{points.map { |point| point_components_mm(point) }.inspect}"
            end

            signature = triangle_signature(points)
            if records_by_signature.key?(signature)
              raise ReconstructionError,
                    "Bulk triangle rebuild received a duplicate triangle: " \
                    "#{signature.inspect}"
            end
            records_by_signature[signature] = record

            indices = points.map do |point|
              key = grid_indices(point)
              point_indices[key] ||= polygon_mesh.add_point(point)
            end
            polygon_mesh.add_polygon(indices)
          end

          filled = entities.fill_from_mesh(polygon_mesh, true, 0)
          unless filled
            raise ReconstructionError, 'fill_from_mesh rejected the normalized triangle complex'
          end

          matched = {}
          entities.grep(@face_class).each do |face|
            next unless face&.valid? && face.vertices.length == 3

            signature = triangle_signature(face.vertices.map(&:position))
            record = records_by_signature[signature]
            next unless record

            if matched.key?(signature)
              raise ReconstructionError,
                    "fill_from_mesh created duplicate triangle faces: " \
                    "#{signature.inspect}"
            end
            matched[signature] = true
            orient_face!(face, record[:source_normal])
            apply_face_metadata(face, record)
          end

          missing = records_by_signature.keys.reject { |signature| matched[signature] }
          unless missing.empty?
            raise ReconstructionError,
                  "fill_from_mesh omitted normalized triangles: " \
                  "count=#{missing.length} samples=#{missing.first(10).inspect}"
          end

          {
            added_faces: matched.length,
            skipped_collinear: 0,
            strategy: :fill_from_mesh
          }
        end

        def apply_face_metadata(face, record)
          face.material = record[:material] if face.respond_to?(:material=)
          face.back_material = record[:back_material] if face.respond_to?(:back_material=)
          face.layer = record[:layer] if face.respond_to?(:layer=) && record[:layer]
        end

        def face_record(face)
          {
            points: face.vertices.map(&:position),
            source_normal: vector_components(face.normal),
            material: face.material,
            back_material: face.back_material,
            layer: face.layer
          }
        end

        def stitch_surface_borders(entities)
          repairs = 0
          ignored_loop_signatures = {}

          loop do
            topology = geometry_counts(entities)
            break if topology[:boundary_edges].zero?

            if repairs >= MAX_STITCH_REPAIRS
              raise ReconstructionError, 'Surface-border stitch exceeded repair limit'
            end

            segment_candidate = surface_border_candidate(entities)
            if segment_candidate
              rebuild_boundary_face(entities, segment_candidate)
              repairs += 1
              next
            end

            loop_candidate = surface_border_loop_candidate(
              entities,
              ignored_loop_signatures
            )
            break unless loop_candidate

            before = geometry_counts(entities)
            face = add_face_allowing_nonplanar_failure(
              entities,
              loop_candidate[:points]
            )

            unless face&.valid?
              ignored_loop_signatures[loop_candidate[:signature]] = true
              next
            end

            after = geometry_counts(entities)
            improved = after[:boundary_edges] < before[:boundary_edges] &&
                       topology_anomaly_score(after) < topology_anomaly_score(before)

            if improved
              repairs += 1
            else
              face.erase! if face.valid?
              ignored_loop_signatures[loop_candidate[:signature]] = true
            end
          end

          { repairs: repairs }
        end

        def add_face_allowing_nonplanar_failure(entities, points)
          entities.add_face(points)
        rescue ArgumentError => e
          raise unless e.message.to_s.downcase.include?('not planar')

          nil
        end

        def surface_border_loop_candidate(entities, ignored_signatures)
          boundary_edges = entities.grep(@edge_class).select do |edge|
            edge.valid? && edge.faces.length == 1
          end
          remaining = boundary_edges.dup

          until remaining.empty?
            seed = remaining.shift
            component = [seed]
            queue = [seed]

            until queue.empty?
              edge = queue.shift
              neighbors = edge.vertices.flat_map(&:edges).select do |candidate|
                candidate.valid? &&
                  candidate.faces.length == 1 &&
                  remaining.include?(candidate)
              end

              neighbors.each do |neighbor|
                remaining.delete(neighbor)
                component << neighbor
                queue << neighbor
              end
            end

            vertices = component.flat_map(&:vertices).uniq
            next unless vertices.length >= 3

            adjacency = vertices.to_h do |vertex|
              [vertex, component.select { |edge| edge.vertices.include?(vertex) }]
            end
            next unless adjacency.values.all? { |edges| edges.length == 2 }

            ordered = ordered_closed_boundary_points(component, vertices, adjacency)
            next unless ordered

            signature = ordered.map { |point| grid_indices(point) }.sort
            next if ignored_signatures[signature]

            return { points: ordered, signature: signature }
          end

          nil
        end

        def ordered_closed_boundary_points(component, vertices, adjacency)
          ordered = []
          start_vertex = vertices.first
          current_vertex = start_vertex
          previous_edge = nil

          component.length.times do
            ordered << current_vertex.position
            next_edge = adjacency.fetch(current_vertex).find do |edge|
              edge != previous_edge
            end
            return nil unless next_edge

            current_vertex = (next_edge.vertices - [current_vertex]).first
            previous_edge = next_edge
          end

          return nil unless current_vertex == start_vertex
          return nil unless ordered.length == component.length

          ordered
        end

        def surface_border_candidate(entities)
          boundary_edges = entities.grep(@edge_class).select do |edge|
            edge.valid? && edge.faces.length == 1
          end
          boundary_vertices = boundary_edges.flat_map(&:vertices).uniq

          boundary_edges.sort_by { |edge| -edge.length.to_f }.each do |edge|
            inserted = boundary_vertices.filter_map do |vertex|
              next if edge.vertices.include?(vertex)

              parameter = point_on_segment_parameter(
                vertex.position,
                edge.start.position,
                edge.end.position,
                GRID_EPSILON_MM
              )
              [parameter, vertex.position] if parameter
            end
            next if inserted.empty?

            return {
              edge: edge,
              face: edge.faces.first,
              inserted: inserted.sort_by(&:first).map(&:last)
            }
          end

          nil
        end

        def rebuild_boundary_face(entities, candidate)
          edge = candidate[:edge]
          face = candidate[:face]
          unless edge&.valid? && face&.valid?
            raise ReconstructionError, 'Invalid surface-border stitch candidate'
          end
          unless face.loops.length == 1
            raise ReconstructionError,
                  'Surface-border stitch supports only a single outer loop'
          end

          vertices = face.outer_loop.vertices
          points = vertices.map(&:position)
          insert_index = nil
          reverse_inserted = false

          vertices.each_index do |index|
            current = vertices[index]
            following = vertices[(index + 1) % vertices.length]

            if current == edge.start && following == edge.end
              insert_index = index + 1
              break
            end
            if current == edge.end && following == edge.start
              insert_index = index + 1
              reverse_inserted = true
              break
            end
          end

          unless insert_index
            raise ReconstructionError,
                  'Surface-border edge not found in owner face loop'
          end

          inserted = reverse_inserted ? candidate[:inserted].reverse : candidate[:inserted]
          expanded = points.dup
          expanded.insert(insert_index, *inserted)
          record = face_record(face)

          face.erase!
          edge.erase! if edge.valid? && edge.faces.empty?

          rebuilt = entities.add_face(expanded)
          unless rebuilt&.valid?
            raise ReconstructionError,
                  'Surface-border owner face could not be rebuilt'
          end

          orient_face!(rebuilt, record[:source_normal])
          apply_face_metadata(rebuilt, record)
          rebuilt
        end
      end
    end
  end
end
