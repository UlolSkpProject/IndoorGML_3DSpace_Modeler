# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Rebuilds a solid from a normalized, unique local-coordinate vertex set.
      #
      # Moving existing SketchUp vertices is deliberately avoided here. Moving
      # can leave topologically distinct vertices at the same coordinate and can
      # make an exported GML ring collapse even while SketchUp reports a solid.
      class LocalVertexNormalizer
        DEFAULT_TOLERANCE_MM = 0.001
        STRICT_COPLANAR_TOLERANCE_MM = 0.000001
        STRICT_COPLANAR_ANGLE_TOLERANCE_DEG = 0.001
        COPLANAR_TOLERANCE_MM = 0.01
        # The successful 7777 work-copy cleanup reached 0.00918 degrees. Keeping
        # the guard at 0.01 degrees rejects shallow-looking but destructive joins.
        COPLANAR_ANGLE_TOLERANCE_DEG = 0.01
        GRID_EPSILON_MM = 0.000001
        COLLINEAR_CROSS_EPSILON_IN2 = 1.0e-12
        MAX_STITCH_REPAIRS = 1_000
        MAX_COPLANAR_PASSES = 20
        MAX_COLLINEAR_REPAIRS = 1_000
        MM_PER_INCH = 25.4

        class Error < StandardError; end
        class ReconstructionError < Error; end
        class DestructiveCoplanarCleanupError < ReconstructionError; end
        class TopologyChangedError < Error; end

        def self.normalize(entity, tolerance_mm = DEFAULT_TOLERANCE_MM)
          new(tolerance_mm).normalize(entity)
        end

        def self.normalized?(entity, tolerance_mm = DEFAULT_TOLERANCE_MM)
          new(tolerance_mm).normalized?(entity)
        end

        def initialize(
          tolerance_mm = DEFAULT_TOLERANCE_MM,
          point_factory: nil,
          vector_factory: nil,
          edge_class: nil,
          face_class: nil
        )
          @tolerance_mm = Float(tolerance_mm)
          raise ArgumentError, 'Local vertex normalize tolerance must be greater than zero' unless @tolerance_mm.positive?

          @point_factory = point_factory || ->(x, y, z) { Geom::Point3d.new(x, y, z) }
          @vector_factory = vector_factory || ->(x, y, z) { Geom::Vector3d.new(x, y, z) }
          @edge_class = edge_class || Sketchup::Edge
          @face_class = face_class || Sketchup::Face
        rescue TypeError, ArgumentError => e
          raise e if e.is_a?(ArgumentError) && e.message.include?('greater than zero')

          raise ArgumentError, "Invalid local vertex normalize tolerance: #{tolerance_mm.inspect}"
        end

        def normalize(entity)
          validate_entity!(entity)
          ensure_unique_definition(entity)

          entities = entity.definition.entities
          before = geometry_counts(entities)
          volume_before_mm3 = solid_volume_mm3(entity)
          source_vertices = geometry_vertices(entities)
          vertex_metrics = normalized_vertex_metrics(source_vertices)
          source_triangles = normalized_triangle_snapshot(entities)
          triangles = conforming_triangle_snapshot(source_triangles)
          raise ReconstructionError, "No reconstructable faces found for #{entity_label(entity)}" if triangles.empty?

          base = rebuild_normalized_base(entities, triangles, entity)
          build = base[:build]
          overlap_repair = base[:overlap_repair]
          pre_stitch = base[:pre_stitch]
          strict_coplanar = base[:strict_coplanar]
          post_stitch = base[:post_stitch]

          broad_cleanup_fallback = nil
          begin
            coplanar = remove_coplanar_shared_edges(
              entities,
              plane_tolerance_mm: COPLANAR_TOLERANCE_MM,
              angle_tolerance_deg: COPLANAR_ANGLE_TOLERANCE_DEG
            )
            broad_topology = geometry_counts(entities)
            unless closed_topology?(broad_topology)
              raise DestructiveCoplanarCleanupError,
                    "Coplanar cleanup changed topology: #{broad_topology.inspect}"
            end
          rescue DestructiveCoplanarCleanupError => e
            broad_cleanup_fallback = e.message
            base = rebuild_normalized_base(entities, triangles, entity)
            build = base[:build]
            overlap_repair = base[:overlap_repair]
            pre_stitch = base[:pre_stitch]
            strict_coplanar = base[:strict_coplanar]
            post_stitch = base[:post_stitch]
            coplanar = empty_coplanar_cleanup_report(fallback_reason: broad_cleanup_fallback)
          end

          collinear = remove_unbranched_collinear_vertices(entities)
          orientation = orient_shell_faces_consistently(entities)
          after = geometry_counts(entities)
          validate_rebuilt_entity!(entity, after)

          final_vertices = geometry_vertices(entities)
          residual_mm = max_grid_residual_mm(final_vertices)
          if residual_mm > GRID_EPSILON_MM
            raise TopologyChangedError,
                  "Rebuilt vertices are off the #{@tolerance_mm} mm grid: residual=#{residual_mm} mm"
          end

          {
            persistent_id: entity.persistent_id,
            name: entity.respond_to?(:name) ? entity.name.to_s : '',
            tolerance_mm: @tolerance_mm,
            coplanar_tolerance_mm: COPLANAR_TOLERANCE_MM,
            vertex_count: source_vertices.length,
            unique_normalized_vertex_count: vertex_metrics[:unique_target_count],
            moved_vertex_count: vertex_metrics[:moved_count],
            merged_vertex_count: source_vertices.length - final_vertices.length,
            max_displacement_mm: vertex_metrics[:max_displacement_mm],
            max_grid_residual_mm: residual_mm,
            max_unprotected_grid_residual_mm: residual_mm,
            protected_coincident_vertex_count: 0,
            normalization_complete: true,
            normalization_passes: [
              { phase: :triangle_rebuild, source_triangles: triangles.length, added_faces: build[:added_faces],
                skipped_collinear: build[:skipped_collinear] },
              { phase: :redundant_overlap_triangle_repair, removed_faces: overlap_repair[:removed_faces] },
              { phase: :surface_border_stitch_before_cleanup, repairs: pre_stitch[:repairs] },
              { phase: :strict_coplanar_cleanup, removed_edges: strict_coplanar[:removed_edges],
                passes: strict_coplanar[:passes] },
              { phase: :surface_border_stitch_after_cleanup, repairs: post_stitch[:repairs] },
              { phase: :coplanar_cleanup, removed_edges: coplanar[:removed_edges], passes: coplanar[:passes] },
              { phase: :collinear_cleanup, removed_vertices: collinear[:removed_vertices] },
              { phase: :face_orientation, reversed_faces: orientation[:reversed_faces] }
            ],
            source_triangle_count: source_triangles.length,
            conforming_triangle_count: triangles.length,
            added_face_count: build[:added_faces],
            skipped_collinear_triangle_count: build[:skipped_collinear],
            surface_border_repair_count: pre_stitch[:repairs] + post_stitch[:repairs],
            redundant_overlap_triangle_removal_count: overlap_repair[:removed_faces],
            strict_coplanar_edge_removal_count: strict_coplanar[:removed_edges],
            coplanar_edge_removal_count: strict_coplanar[:removed_edges] + coplanar[:removed_edges],
            collinear_vertex_removal_count: collinear[:removed_vertices],
            reoriented_face_count: orientation[:reversed_faces],
            max_coplanar_plane_deviation_mm: coplanar[:max_plane_deviation_mm],
            max_coplanar_angle_deg: coplanar[:max_angle_deg],
            normalization_strategy: :rebuild,
            direct_vertex_move_fallback: nil,
            coplanar_cleanup_fallback: broad_cleanup_fallback || strict_coplanar[:fallback_reason],
            volume_before_mm3: volume_before_mm3,
            volume_after_mm3: solid_volume_mm3(entity),
            topology_before: before,
            topology: after,
            topology_changed: before != after,
            manifold: true
          }
        end

        # A locally normalized entity has every local vertex on the requested
        # decimal grid and has no topologically separate vertices occupying the
        # same grid coordinate. The duplicate check is required because such a
        # solid can be manifold in SketchUp but collapse an exported GML ring.
        def normalized?(entity)
          return false unless entity&.respond_to?(:valid?) && entity.valid?
          return false unless entity.respond_to?(:definition) && entity.definition&.valid?

          vertices = geometry_vertices(entity.definition.entities)
          return false if vertices.empty?

          occupied_grid_points = {}
          vertices.each do |vertex|
            point = vertex.position
            return false unless point_on_grid?(point)

            key = grid_indices(point)
            return false if occupied_grid_points[key]

            occupied_grid_points[key] = true
          end
          true
        rescue StandardError
          false
        end

        private

        def rebuild_normalized_base(entities, triangles, entity)
          erase_source_geometry(entities)
          build = rebuild_triangles(entities, triangles)
          overlap_repair = remove_redundant_overlap_triangles(entities)
          pre_stitch = stitch_surface_borders(entities)
          strict_coplanar = begin
            remove_coplanar_shared_edges(
              entities,
              plane_tolerance_mm: STRICT_COPLANAR_TOLERANCE_MM,
              angle_tolerance_deg: STRICT_COPLANAR_ANGLE_TOLERANCE_DEG
            )
          rescue DestructiveCoplanarCleanupError => e
            erase_source_geometry(entities)
            build = rebuild_triangles(entities, triangles)
            overlap_repair = remove_redundant_overlap_triangles(entities)
            pre_stitch = stitch_surface_borders(entities)
            empty_coplanar_cleanup_report(fallback_reason: e.message)
          end
          post_stitch = stitch_surface_borders(entities)
          intermediate = geometry_counts(entities)
          if closed_surface?(intermediate) && intermediate[:orientation_conflicts].to_i.positive?
            orient_shell_faces_consistently(entities)
            intermediate = geometry_counts(entities)
          end
          if !closed_topology?(intermediate) && strict_coplanar[:removed_edges].to_i.positive?
            fallback_reason = "Strict coplanar cleanup changed topology: #{intermediate.inspect}"
            erase_source_geometry(entities)
            build = rebuild_triangles(entities, triangles)
            overlap_repair = remove_redundant_overlap_triangles(entities)
            pre_stitch = stitch_surface_borders(entities)
            strict_coplanar = empty_coplanar_cleanup_report(fallback_reason: fallback_reason)
            post_stitch = stitch_surface_borders(entities)
            intermediate = geometry_counts(entities)
            if closed_surface?(intermediate) && intermediate[:orientation_conflicts].to_i.positive?
              orient_shell_faces_consistently(entities)
              intermediate = geometry_counts(entities)
            end
          end
          unless closed_topology?(intermediate)
            raise TopologyChangedError,
                  "Rebuilt surface is open before coplanar cleanup: #{entity_label(entity)} #{intermediate.inspect}"
          end
          {
            build: build,
            overlap_repair: overlap_repair,
            pre_stitch: pre_stitch,
            strict_coplanar: strict_coplanar,
            post_stitch: post_stitch
          }
        end

        def empty_coplanar_cleanup_report(fallback_reason: nil)
          {
            removed_edges: 0,
            unchanged_edges: 0,
            passes: [],
            max_plane_deviation_mm: 0.0,
            max_angle_deg: 0.0,
            fallback_reason: fallback_reason
          }
        end

        def validate_entity!(entity)
          unless entity&.respond_to?(:valid?) && entity.valid? && entity.respond_to?(:definition) && entity.definition&.valid?
            raise ArgumentError, 'Valid SketchUp group or component instance expected'
          end
          return if entity.respond_to?(:manifold?) && entity.manifold? == true

          raise TopologyChangedError,
                "Local vertex normalize requires a manifold solid: #{entity_label(entity)}"
        end

        def validate_rebuilt_entity!(entity, topology)
          unless closed_topology?(topology) && entity.valid? && entity.manifold? == true
            raise TopologyChangedError,
                  "Local vertex reconstruction damaged topology: #{entity_label(entity)} #{topology.inspect}"
          end
        end

        def closed_topology?(topology)
          closed_surface?(topology) && topology[:orientation_conflicts].zero?
        end

        def closed_surface?(topology)
          topology[:faces].positive? &&
            topology[:boundary_edges].zero? &&
            topology[:wire_edges].zero? &&
            topology[:overused_edges].zero?
        end

        def entity_label(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          persistent_id = entity.respond_to?(:persistent_id) ? entity.persistent_id : nil
          "name=#{name.inspect} persistent_id=#{persistent_id.inspect}"
        rescue StandardError
          entity.class.to_s
        end

        def ensure_unique_definition(entity)
          definition = entity.definition
          return unless definition.respond_to?(:instances)
          return unless Array(definition.instances).length > 1
          return entity.make_unique if entity.respond_to?(:make_unique)

          raise ArgumentError, 'Shared component definition cannot be normalized independently'
        end

        def geometry_vertices(entities)
          entities.grep(@edge_class).flat_map(&:vertices).uniq
        end

        def geometry_counts(entities)
          edges = entities.grep(@edge_class)
          {
            faces: entities.grep(@face_class).length,
            edges: edges.length,
            vertices: edges.flat_map(&:vertices).uniq.length,
            boundary_edges: edges.count { |edge| edge.faces.length == 1 },
            wire_edges: edges.count { |edge| edge.faces.empty? },
            overused_edges: edges.count { |edge| edge.faces.length > 2 },
            orientation_conflicts: edges.count do |edge|
              edge.faces.length == 2 && edge.reversed_in?(edge.faces[0]) == edge.reversed_in?(edge.faces[1])
            rescue StandardError
              false
            end
          }
        end

        def normalized_vertex_metrics(vertices)
          keys = {}
          moved_count = 0
          max_displacement_mm = 0.0
          vertices.each do |vertex|
            target = normalized_target(vertex.position)
            keys[grid_indices(target)] = true
            displacement_mm = point_distance_mm(vertex.position, target)
            moved_count += 1 if displacement_mm > GRID_EPSILON_MM
            max_displacement_mm = displacement_mm if displacement_mm > max_displacement_mm
          end
          {
            unique_target_count: keys.length,
            moved_count: moved_count,
            max_displacement_mm: max_displacement_mm
          }
        end

        def normalized_triangle_snapshot(entities)
          triangles = []
          signatures = {}
          entities.grep(@face_class).each do |face|
            mesh = face.mesh(0)
            mesh.polygons.each do |polygon|
              points = polygon.map { |index| normalized_target(mesh.point_at(index.abs)) }
              triangulate_polygon(points).each do |triangle_points|
                keys = triangle_points.map { |point| grid_indices(point) }
                signature = keys.sort
                if signatures[signature]
                  raise ReconstructionError,
                        "Duplicate normalized triangle detected in #{entity_label_from_face(face)}: #{signature.inspect}"
                end
                signatures[signature] = true
                triangles << {
                  points: triangle_points,
                  source_normal: vector_components(face.normal),
                  material: face.material,
                  back_material: face.back_material,
                  layer: face.layer
                }
              end
            end
          end
          triangles
        end

        def conforming_triangle_snapshot(source_triangles)
          all_points = source_triangles.flat_map { |record| record[:points] }
          unique_points = {}
          all_points.each { |point| unique_points[grid_indices(point)] ||= point }
          candidates = unique_points.values
          signatures = {}

          source_triangles.flat_map do |record|
            next [] if collinear_triangle?(record[:points])

            boundary = triangle_boundary_with_segment_vertices(record[:points], candidates)
            triangulate_convex_boundary(boundary, candidates).map do |points|
              signature = points.map { |point| grid_indices(point) }.sort
              if signatures[signature]
                raise ReconstructionError, "Duplicate conforming triangle detected: #{signature.inspect}"
              end

              signatures[signature] = true
              record.merge(points: points)
            end
          end
        end

        def triangle_boundary_with_segment_vertices(points, candidates)
          boundary = []
          3.times do |index|
            start_point = points[index]
            end_point = points[(index + 1) % 3]
            boundary << start_point
            inserted = candidates.filter_map do |candidate|
              next if grid_indices(candidate) == grid_indices(start_point)
              next if grid_indices(candidate) == grid_indices(end_point)

              parameter = point_on_segment_parameter(
                candidate,
                start_point,
                end_point,
                GRID_EPSILON_MM
              )
              [parameter, candidate] if parameter
            end
            boundary.concat(inserted.sort_by(&:first).map(&:last))
          end
          remove_consecutive_duplicate_points(boundary)
        end

        # The boundary is the original triangle with optional collinear points
        # inserted on its three edges, so it is convex. Removing any
        # non-collinear ear preserves every split boundary segment and avoids
        # the degenerate fan triangles that recreate T-junctions.
        def triangulate_convex_boundary(points, candidates = points)
          remaining = remove_consecutive_duplicate_points(points)
          triangles = []
          while remaining.length > 3
            ear_index = remaining.each_index.find do |index|
              previous_point = remaining[(index - 1) % remaining.length]
              current_point = remaining[index]
              following_point = remaining[(index + 1) % remaining.length]
              triangle = [previous_point, current_point, following_point]
              !collinear_triangle?(triangle) &&
                !segment_has_interior_candidate?(previous_point, following_point, candidates)
            end
            break unless ear_index

            triangles << [
              remaining[(ear_index - 1) % remaining.length],
              remaining[ear_index],
              remaining[(ear_index + 1) % remaining.length]
            ]
            remaining.delete_at(ear_index)
          end
          triangles << remaining unless collinear_triangle?(remaining)
          triangles
        end

        def segment_has_interior_candidate?(start_point, end_point, candidates)
          start_key = grid_indices(start_point)
          end_key = grid_indices(end_point)
          candidates.any? do |candidate|
            candidate_key = grid_indices(candidate)
            next false if candidate_key == start_key || candidate_key == end_key

            point_on_segment_parameter(
              candidate,
              start_point,
              end_point,
              GRID_EPSILON_MM
            )
          end
        end

        def triangulate_polygon(points)
          compact = remove_consecutive_duplicate_points(points)
          return [] if compact.length < 3
          return [compact] if compact.length == 3

          (1...(compact.length - 1)).map { |index| [compact[0], compact[index], compact[index + 1]] }
        end

        def remove_consecutive_duplicate_points(points)
          compact = []
          points.each do |point|
            compact << point if compact.empty? || grid_indices(compact.last) != grid_indices(point)
          end
          compact.pop if compact.length > 1 && grid_indices(compact.first) == grid_indices(compact.last)
          compact
        end

        def erase_source_geometry(entities)
          geometry = entities.to_a.select { |item| item.is_a?(@face_class) || item.is_a?(@edge_class) }
          entities.erase_entities(geometry) unless geometry.empty?
        end

        def rebuild_triangles(entities, triangles)
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
                    "add_face failed for normalized triangle #{points.map { |point| point_components_mm(point) }.inspect}"
            end
            orient_face!(face, record[:source_normal])
            face.material = record[:material] if face.respond_to?(:material=)
            face.back_material = record[:back_material] if face.respond_to?(:back_material=)
            face.layer = record[:layer] if face.respond_to?(:layer=) && record[:layer]
            added_faces += 1
          end
          { added_faces: added_faces, skipped_collinear: skipped_collinear }
        end

        # SketchUp may intersect two normalized, nearly coincident surface
        # patches while add_face is running. The characteristic artifact is a
        # triangular cap with two overused edges and one boundary edge. Removing
        # only that cap restores the intended two-face incidence on the shared
        # edges; its remaining boundary edge becomes an unused wire and is
        # removed with it.
        def remove_redundant_overlap_triangles(entities)
          removed_faces = 0
          repairs = []
          ignored_signatures = {}
          loop do
            before = geometry_counts(entities)
            candidate = entities.grep(@face_class).find do |face|
              next false unless face.valid? && face.edges.length == 3

              signature = face.vertices.map { |vertex| grid_indices(vertex.position) }.sort
              next false if ignored_signatures[signature]

              face_counts = face.edges.map { |edge| edge.faces.length }
              overused_count = face_counts.count { |count| count > 2 }
              boundary_count = face_counts.count { |count| count == 1 }
              (overused_count >= 2 && boundary_count >= 1) || overused_count == 3
            end
            break unless candidate

            signature = candidate.vertices.map { |vertex| grid_indices(vertex.position) }.sort
            points = candidate.vertices.map(&:position)
            points_mm = candidate.vertices.map { |vertex| point_components_mm(vertex.position) }
            normal = vector_components(candidate.normal)
            material = candidate.material
            back_material = candidate.back_material
            layer = candidate.layer
            candidate.erase!
            entities.grep(@edge_class).select { |edge| edge.valid? && edge.faces.empty? }.each(&:erase!)
            after = geometry_counts(entities)
            unless topology_anomaly_score(after) < topology_anomaly_score(before)
              restored = entities.add_face(points)
              unless restored&.valid?
                raise ReconstructionError,
                      "Redundant overlap triangle repair could not restore rejected candidate: #{before.inspect} -> #{after.inspect}"
              end
              orient_face!(restored, normal)
              restored.material = material if restored.respond_to?(:material=)
              restored.back_material = back_material if restored.respond_to?(:back_material=)
              restored.layer = layer if restored.respond_to?(:layer=) && layer
              ignored_signatures[signature] = true
              next
            end

            removed_faces += 1
            repairs << { points_mm: points_mm, before: before, after: after }
          end
          { removed_faces: removed_faces, repairs: repairs }
        end

        def topology_anomaly_score(topology)
          topology[:boundary_edges].to_i + topology[:wire_edges].to_i + topology[:overused_edges].to_i
        end

        def stitch_surface_borders(entities)
          repairs = 0
          ignored_loop_signatures = {}
          loop do
            topology = geometry_counts(entities)
            break if topology[:boundary_edges].zero?
            raise ReconstructionError, 'Surface-border stitch exceeded repair limit' if repairs >= MAX_STITCH_REPAIRS

            candidate = surface_border_candidate(entities)
            if candidate
              rebuild_boundary_face(entities, candidate)
              repairs += 1
              next
            end

            loop_candidate = surface_border_loop_candidate(entities, ignored_loop_signatures)
            break unless loop_candidate

            before = geometry_counts(entities)
            face = begin
              entities.add_face(loop_candidate[:points])
            rescue ArgumentError => e
              raise unless e.message.to_s.downcase.include?('not planar')

              nil
            end
            unless face&.valid?
              ignored_loop_signatures[loop_candidate[:signature]] = true
              next
            end
            after = geometry_counts(entities)
            if after[:boundary_edges] < before[:boundary_edges] &&
               topology_anomaly_score(after) < topology_anomaly_score(before)
              repairs += 1
            else
              face.erase! if face.valid?
              ignored_loop_signatures[loop_candidate[:signature]] = true
            end
          end
          { repairs: repairs }
        end

        def surface_border_loop_candidate(entities, ignored_signatures)
          boundary_edges = entities.grep(@edge_class).select { |edge| edge.valid? && edge.faces.length == 1 }
          remaining = boundary_edges.dup
          until remaining.empty?
            seed = remaining.shift
            component = [seed]
            queue = [seed]
            until queue.empty?
              edge = queue.shift
              neighbors = edge.vertices.flat_map(&:edges).select do |candidate|
                candidate.valid? && candidate.faces.length == 1 && remaining.include?(candidate)
              end
              neighbors.each do |neighbor|
                remaining.delete(neighbor)
                component << neighbor
                queue << neighbor
              end
            end

            vertices = component.flat_map(&:vertices).uniq
            adjacency = vertices.to_h do |vertex|
              [vertex, component.select { |edge| edge.vertices.include?(vertex) }]
            end
            next unless vertices.length >= 3
            next unless adjacency.values.all? { |edges| edges.length == 2 }

            ordered = []
            start_vertex = vertices.first
            current_vertex = start_vertex
            previous_edge = nil
            component.length.times do
              ordered << current_vertex.position
              next_edge = adjacency.fetch(current_vertex).find { |edge| edge != previous_edge }
              break unless next_edge

              current_vertex = (next_edge.vertices - [current_vertex]).first
              previous_edge = next_edge
            end
            next unless current_vertex == start_vertex
            next unless ordered.length == component.length

            signature = ordered.map { |point| grid_indices(point) }.sort
            next if ignored_signatures[signature]

            return { points: ordered, signature: signature }
          end
          nil
        end

        def surface_border_candidate(entities)
          boundary_edges = entities.grep(@edge_class).select { |edge| edge.valid? && edge.faces.length == 1 }
          boundary_vertices = boundary_edges.flat_map(&:vertices).uniq
          boundary_edges.sort_by { |edge| -edge.length.to_f }.each do |edge|
            start_point = edge.start.position
            end_point = edge.end.position
            inserted = boundary_vertices.filter_map do |vertex|
              next if edge.vertices.include?(vertex)

              parameter = point_on_segment_parameter(vertex.position, start_point, end_point, GRID_EPSILON_MM)
              [parameter, vertex.position] if parameter
            end
            next if inserted.empty?

            return { edge: edge, face: edge.faces.first, inserted: inserted.sort_by(&:first).map(&:last) }
          end
          nil
        end

        def rebuild_boundary_face(entities, candidate)
          edge = candidate[:edge]
          face = candidate[:face]
          raise ReconstructionError, 'Invalid surface-border stitch candidate' unless edge&.valid? && face&.valid?
          raise ReconstructionError, 'Surface-border stitch only supports outer-loop triangles' unless face.loops.length == 1

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
            elsif current == edge.end && following == edge.start
              insert_index = index + 1
              reverse_inserted = true
              break
            end
          end
          raise ReconstructionError, 'Surface-border edge not found in owner face loop' unless insert_index

          inserted = reverse_inserted ? candidate[:inserted].reverse : candidate[:inserted]
          expanded = points.dup
          expanded.insert(insert_index, *inserted)
          normal = vector_components(face.normal)
          material = face.material
          back_material = face.back_material
          layer = face.layer

          face.erase!
          edge.erase! if edge.valid? && edge.faces.empty?
          rebuilt = entities.add_face(expanded)
          raise ReconstructionError, 'Surface-border owner face could not be rebuilt' unless rebuilt&.valid?

          orient_face!(rebuilt, normal)
          rebuilt.material = material if rebuilt.respond_to?(:material=)
          rebuilt.back_material = back_material if rebuilt.respond_to?(:back_material=)
          rebuilt.layer = layer if rebuilt.respond_to?(:layer=) && layer
          rebuilt
        end

        def remove_coplanar_shared_edges(entities, plane_tolerance_mm:, angle_tolerance_deg:)
          removed = 0
          unchanged = 0
          ignored_edge_ids = {}
          pass_reports = []
          max_deviation_mm = 0.0
          max_angle_deg = 0.0

          MAX_COPLANAR_PASSES.times do |pass_index|
            candidates = entities.grep(@edge_class).filter_map do |edge|
              next if ignored_edge_ids[stable_entity_id(edge)]

              coplanar_edge_metrics(
                edge,
                plane_tolerance_mm: plane_tolerance_mm,
                angle_tolerance_deg: angle_tolerance_deg
              )
            end
            break if candidates.empty?

            pass_removed = 0
            candidates.each do |entry|
              edge = entry[:edge]
              next unless edge&.valid? && edge.faces.length == 2
              next unless coplanar_edge_metrics(
                edge,
                plane_tolerance_mm: plane_tolerance_mm,
                angle_tolerance_deg: angle_tolerance_deg
              )

              faces_before = entities.grep(@face_class).length
              edge_id = stable_entity_id(edge)
              begin
                edge.erase!
              rescue ArgumentError => e
                ignored_edge_ids[edge_id] = true
                unchanged += 1
                next if e.message.to_s.downcase.include?('not planar')

                raise
              end
              faces_after = entities.grep(@face_class).length
              face_reduction = faces_before - faces_after
              if face_reduction.zero?
                ignored_edge_ids[edge_id] = true
                unchanged += 1
                next
              end
              unless face_reduction == 1
                raise DestructiveCoplanarCleanupError,
                      "Coplanar edge removal was destructive at tolerance=#{plane_tolerance_mm}mm " \
                      "angle=#{entry[:angle_deg]}deg deviation=#{entry[:plane_deviation_mm]}mm: " \
                      "faces #{faces_before} -> #{faces_after}"
              end
              pass_removed += 1
              removed += 1
              max_deviation_mm = entry[:plane_deviation_mm] if entry[:plane_deviation_mm] > max_deviation_mm
              max_angle_deg = entry[:angle_deg] if entry[:angle_deg] > max_angle_deg
            end
            break if pass_removed.zero?

            pass_reports << { pass: pass_index + 1, removed_edges: pass_removed }
          end

          {
            removed_edges: removed,
            unchanged_edges: unchanged,
            passes: pass_reports,
            max_plane_deviation_mm: max_deviation_mm,
            max_angle_deg: max_angle_deg
          }
        end

        def coplanar_edge_metrics(edge, plane_tolerance_mm:, angle_tolerance_deg:)
          return nil unless edge&.valid? && edge.faces.length == 2

          face_a, face_b = edge.faces
          dot = vector_dot(vector_components(face_a.normal), vector_components(face_b.normal))
          return nil unless dot.positive?

          angle_deg = Math.acos([[dot, -1.0].max, 1.0].min) * 180.0 / Math::PI
          return nil if angle_deg > angle_tolerance_deg

          deviation_mm = [
            face_plane_deviation_mm(face_a, face_b),
            face_plane_deviation_mm(face_b, face_a)
          ].max
          return nil if deviation_mm > plane_tolerance_mm

          { edge: edge, plane_deviation_mm: deviation_mm, angle_deg: angle_deg }
        rescue StandardError
          nil
        end

        def stable_entity_id(entity)
          return entity.persistent_id if entity.respond_to?(:persistent_id)

          entity.object_id
        rescue StandardError
          entity.object_id
        end

        def face_plane_deviation_mm(source_face, reference_face)
          plane = reference_face.plane.map(&:to_f)
          denominator = Math.sqrt((plane[0]**2) + (plane[1]**2) + (plane[2]**2))
          return Float::INFINITY if denominator.zero?

          source_face.vertices.map do |vertex|
            point = vertex.position
            numerator = ((plane[0] * point.x.to_f) + (plane[1] * point.y.to_f) +
                         (plane[2] * point.z.to_f) + plane[3]).abs
            numerator * MM_PER_INCH / denominator
          end.max || 0.0
        end

        def remove_unbranched_collinear_vertices(entities)
          removed = 0
          MAX_COLLINEAR_REPAIRS.times do
            candidate = geometry_vertices(entities).find { |vertex| removable_collinear_vertex?(vertex) }
            break unless candidate

            rebuild_faces_without_vertex(entities, candidate)
            removed += 1
          end
          { removed_vertices: removed }
        end

        def orient_shell_faces_consistently(entities)
          visited = {}
          reversed_faces = 0

          entities.grep(@face_class).each do |seed|
            next unless seed.valid?
            next if visited[stable_entity_id(seed)]

            visited[stable_entity_id(seed)] = true
            queue = [seed]
            until queue.empty?
              face = queue.shift
              face.edges.each do |edge|
                next unless edge.valid? && edge.faces.length == 2

                neighbor = (edge.faces - [face]).first
                next unless neighbor&.valid?

                neighbor_id = stable_entity_id(neighbor)
                conflict = edge.reversed_in?(face) == edge.reversed_in?(neighbor)
                if visited[neighbor_id]
                  if conflict
                    raise TopologyChangedError,
                          "Closed shell is not consistently orientable at edge #{stable_entity_id(edge)}"
                  end
                  next
                end

                if conflict
                  neighbor.reverse!
                  reversed_faces += 1
                end
                visited[neighbor_id] = true
                queue << neighbor
              end
            end
          end

          { reversed_faces: reversed_faces }
        end

        def removable_collinear_vertex?(vertex)
          return false unless vertex.valid? && vertex.edges.length == 2 && vertex.faces.length == 2
          return false unless vertex.faces.all? { |face| face.valid? && face.loops.length == 1 && face.vertices.length > 3 }

          point = vertex.position
          other_points = vertex.edges.map do |edge|
            (edge.vertices - [vertex]).first.position
          end
          point_on_segment_parameter(point, other_points[0], other_points[1], GRID_EPSILON_MM)
        rescue StandardError
          false
        end

        def rebuild_faces_without_vertex(entities, vertex)
          records = vertex.faces.map do |face|
            {
              points: face.outer_loop.vertices.reject { |item| item == vertex }.map(&:position),
              normal: vector_components(face.normal),
              material: face.material,
              back_material: face.back_material,
              layer: face.layer
            }
          end
          obsolete_edges = vertex.edges.to_a
          vertex.faces.to_a.each { |face| face.erase! if face.valid? }
          obsolete_edges.each { |edge| edge.erase! if edge.valid? && edge.faces.empty? }

          records.each do |record|
            face = entities.add_face(record[:points])
            raise ReconstructionError, 'Collinear vertex cleanup could not rebuild adjacent face' unless face&.valid?

            orient_face!(face, record[:normal])
            face.material = record[:material] if face.respond_to?(:material=)
            face.back_material = record[:back_material] if face.respond_to?(:back_material=)
            face.layer = record[:layer] if face.respond_to?(:layer=) && record[:layer]
          end
        end

        def point_on_segment_parameter(point, start_point, end_point, tolerance_mm)
          ab = [end_point.x.to_f - start_point.x.to_f,
                end_point.y.to_f - start_point.y.to_f,
                end_point.z.to_f - start_point.z.to_f]
          ap = [point.x.to_f - start_point.x.to_f,
                point.y.to_f - start_point.y.to_f,
                point.z.to_f - start_point.z.to_f]
          length_squared = vector_dot(ab, ab)
          return nil if length_squared.zero?

          parameter = vector_dot(ap, ab) / length_squared
          return nil unless parameter > 1.0e-9 && parameter < (1.0 - 1.0e-9)

          projection = [start_point.x.to_f + (ab[0] * parameter),
                        start_point.y.to_f + (ab[1] * parameter),
                        start_point.z.to_f + (ab[2] * parameter)]
          distance_mm = Math.sqrt(
            ((point.x.to_f - projection[0])**2) +
            ((point.y.to_f - projection[1])**2) +
            ((point.z.to_f - projection[2])**2)
          ) * MM_PER_INCH
          distance_mm <= tolerance_mm ? parameter : nil
        end

        def collinear_triangle?(points)
          return true unless points.length == 3

          ab = vector_between(points[0], points[1])
          ac = vector_between(points[0], points[2])
          vector_length(vector_cross(ab, ac)) <= COLLINEAR_CROSS_EPSILON_IN2
        end

        def orient_face!(face, source_normal)
          face.reverse! if vector_dot(vector_components(face.normal), source_normal).negative?
        end

        def normalized_target(point)
          indices = grid_indices(point)
          @point_factory.call(
            indices[0] * @tolerance_mm / MM_PER_INCH,
            indices[1] * @tolerance_mm / MM_PER_INCH,
            indices[2] * @tolerance_mm / MM_PER_INCH
          )
        end

        def grid_indices(point)
          [point.x, point.y, point.z].map do |coordinate|
            ((coordinate.to_f * MM_PER_INCH) / @tolerance_mm).round
          end
        end

        def max_grid_residual_mm(vertices)
          vertices.flat_map do |vertex|
            point = vertex.position
            [point.x, point.y, point.z].map do |coordinate|
              coordinate_mm = coordinate.to_f * MM_PER_INCH
              (coordinate_mm - ((coordinate_mm / @tolerance_mm).round * @tolerance_mm)).abs
            end
          end.max || 0.0
        end

        def point_on_grid?(point)
          [point.x, point.y, point.z].all? do |coordinate|
            coordinate_mm = coordinate.to_f * MM_PER_INCH
            residual_mm = (coordinate_mm - ((coordinate_mm / @tolerance_mm).round * @tolerance_mm)).abs
            residual_mm <= GRID_EPSILON_MM
          end
        end

        def point_distance_mm(point_a, point_b)
          Math.sqrt(
            ((point_a.x.to_f - point_b.x.to_f)**2) +
            ((point_a.y.to_f - point_b.y.to_f)**2) +
            ((point_a.z.to_f - point_b.z.to_f)**2)
          ) * MM_PER_INCH
        end

        def point_components_mm(point)
          [point.x.to_f, point.y.to_f, point.z.to_f].map { |value| value * MM_PER_INCH }
        end

        def vector_components(vector)
          [vector.x.to_f, vector.y.to_f, vector.z.to_f]
        end

        def vector_between(point_a, point_b)
          [point_b.x.to_f - point_a.x.to_f,
           point_b.y.to_f - point_a.y.to_f,
           point_b.z.to_f - point_a.z.to_f]
        end

        def vector_dot(vector_a, vector_b)
          (vector_a[0] * vector_b[0]) + (vector_a[1] * vector_b[1]) + (vector_a[2] * vector_b[2])
        end

        def vector_cross(vector_a, vector_b)
          [
            (vector_a[1] * vector_b[2]) - (vector_a[2] * vector_b[1]),
            (vector_a[2] * vector_b[0]) - (vector_a[0] * vector_b[2]),
            (vector_a[0] * vector_b[1]) - (vector_a[1] * vector_b[0])
          ]
        end

        def vector_length(vector)
          Math.sqrt(vector_dot(vector, vector))
        end

        def entity_label_from_face(face)
          "face_persistent_id=#{face.persistent_id if face.respond_to?(:persistent_id)}"
        rescue StandardError
          face.class.to_s
        end

        def solid_volume_mm3(entity)
          entity.volume.to_f * (MM_PER_INCH**3)
        rescue StandardError
          nil
        end
      end
    end
  end
end
