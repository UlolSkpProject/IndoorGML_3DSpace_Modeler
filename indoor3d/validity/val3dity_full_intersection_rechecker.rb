# frozen_string_literal: true

require_relative '../utils/geometry'
require_relative '../infrastructure/scene/entity_copy_helper'
require_relative 'validation_error_geometry_resolver'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Full-Solid Boolean implementation retained only as the conservative
        # confirmation and recovery engine for the clipped-mesh rechecker.
        class Val3dityFullIntersectionRechecker
          def initialize(indoor_model:, tolerance:, model: nil, logger: nil)
            @indoor_model = indoor_model
            @tolerance = tolerance
            @model = model || indoor_model&.model
            @logger = logger || (defined?(IndoorCore::Logger) && IndoorCore::Logger)
            @pair_analysis = {}
            @cell_geometry = {}
            @cell_spaces_by_report_id = nil
            ValidationErrorGeometryResolver.clear_overlap_geometry(model: @model) if @model
          end

          def pair_analysis(cell_id1, cell_id2)
            key = pair_key(cell_id1, cell_id2)
            @pair_analysis[key] ||= analyze_pair(cell_id1, cell_id2)
          end

          def best_candidate(candidates, code)
            Array(candidates).max_by do |candidate|
              signed_score = code == 701 && candidate[:distance].to_f.negative? ? 1 : 0
              [signed_score, candidate[:overlap_area].to_f, -candidate[:distance].to_f.abs]
            end
          end

          def missing_pair_reason(_code)
            'opposite-normal face pair not found'
          end

          def tolerated_reason(code, _candidate)
            direction = code == 701 ?
              'SketchUp Boolean non-reproduction' :
              'near-coplanar shared-face adjacency'
            "opposite-normal face pair has signed #{direction} distance within #{@tolerance * 25.4} mm"
          end

          private

          def analyze_pair(cell_id1, cell_id2)
            cell1 = model_cell_geometry(cell_id1)
            return inconclusive(cell_id1, cell_id2, cell1[:reason]) unless cell1[:status] == :ok

            cell2 = model_cell_geometry(cell_id2)
            return inconclusive(cell_id1, cell_id2, cell2[:reason]) unless cell2[:status] == :ok

            adjacency_candidates = shared_face_candidates(cell1[:faces], cell2[:faces])
            intersection = model_solid_intersection_for_pair(
              cell1[:entity], cell2[:entity], cell_id1, cell_id2
            )
            intersection = resolve_non_solid_intersection(
              intersection, adjacency_candidates
            )

            {
              status: :ok,
              cells: [cell_id1, cell_id2],
              cell1: cell1,
              cell2: cell2,
              adjacency_candidates: adjacency_candidates,
              intersection: intersection
            }
          rescue StandardError => e
            inconclusive(
              cell_id1,
              cell_id2,
              "MODEL_GEOMETRY_RECHECK_FAILED: #{e.class}: #{e.message}"
            )
          end

          def inconclusive(cell_id1, cell_id2, reason)
            { status: :inconclusive, cells: [cell_id1, cell_id2], reason: reason }
          end

          def pair_key(cell_id1, cell_id2)
            [cell_id1, cell_id2].sort.join('|')
          end

          def model_cell_geometry(report_cell_id)
            @cell_geometry[report_cell_id] ||= begin
              cell_space = cell_spaces_by_report_id[report_cell_id]
              if cell_space.nil?
                { status: :inconclusive, reason: "CELLSPACE_NOT_FOUND: #{report_cell_id}" }
              else
                entity = cell_space.sketchup_group
                if !(entity&.valid?)
                  { status: :inconclusive, reason: "CELLSPACE_ENTITY_INVALID: #{report_cell_id}" }
                else
                  faces = entity_faces(entity)
                  if faces.empty?
                    { status: :inconclusive, reason: "CELLSPACE_GEOMETRY_UNAVAILABLE: #{report_cell_id}" }
                  else
                    { status: :ok, cell_space: cell_space, entity: entity, faces: faces }
                  end
                end
              end
            end
          end

          def cell_spaces_by_report_id
            @cell_spaces_by_report_id ||= begin
              cell_spaces = Array(@indoor_model&.cell_spaces)
              index = cell_spaces.each_with_object({}) do |cell_space, result|
                runtime_id = cell_space&.id.to_s
                result[runtime_id] = cell_space unless runtime_id.empty?
              end
              used_report_ids = {}
              cell_spaces.each do |cell_space|
                normalized_id = safe_report_id(cell_space&.id)
                normalized_id = 'missing' if normalized_id.empty?
                base = "cell_#{normalized_id}"
                report_id = base
                suffix = 2
                while used_report_ids[report_id]
                  report_id = "#{base}_#{suffix}"
                  suffix += 1
                end
                used_report_ids[report_id] = true
                index[report_id] = cell_space
              end
              index
            end
          end

          def safe_report_id(value)
            value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
          end

          def entity_faces(entity)
            Utils::Geometry.entity_faces_in_parent_space(entity)
          end

          def shared_face_candidates(faces1, faces2)
            candidates = []
            faces1.each_with_index do |face1, index1|
              faces2.each_with_index do |face2, index2|
                next unless Utils::Geometry.normals_opposite?(
                  face1[:normal], face2[:normal]
                )

                distance = face_pair_signed_distance(face1, face2)
                next unless distance.abs <= @tolerance

                overlap = coplanar_overlap_polygons(face1, face2, @tolerance)
                next unless overlap[:area] > Utils::Geometry.area_tolerance(@tolerance)

                candidates << {
                  face1_index: index1,
                  face2_index: index2,
                  face1: face1,
                  face2: face2,
                  distance: distance,
                  penetration_depth: [-distance, 0.0].max,
                  overlap_area: overlap[:area],
                  overlap_polygons: overlap[:polygons],
                  axis: Utils::Geometry.dominant_axis(face1[:normal]),
                  normal: face1[:normal],
                  plane1: plane_constant(face1[:normal], face1[:points].first),
                  plane2: plane_constant(face1[:normal], face2[:points].first)
                }
              end
            end
            candidates
          end

          def coplanar_overlap_polygons(face1, face2, tolerance)
            return { area: 0.0, polygons: [] } if
              face1[:triangles].empty? || face2[:triangles].empty?

            axis = Utils::Geometry.dominant_axis(face1[:normal])
            outer = triangle_set_overlap(
              face1[:triangles], face2[:triangles], axis, tolerance
            )
            removed_by_face1_holes = Array(face1[:interior_triangles]).sum do |holes|
              triangle_set_overlap(holes, face2[:triangles], axis, tolerance)[:area]
            end
            removed_by_face2_holes = Array(face2[:interior_triangles]).sum do |holes|
              triangle_set_overlap(face1[:triangles], holes, axis, tolerance)[:area]
            end
            restored_double_subtraction = Array(face1[:interior_triangles]).sum do |holes1|
              Array(face2[:interior_triangles]).sum do |holes2|
                triangle_set_overlap(holes1, holes2, axis, tolerance)[:area]
              end
            end
            area = outer[:area] - removed_by_face1_holes -
                   removed_by_face2_holes + restored_double_subtraction
            { area: [area, 0.0].max, polygons: outer[:polygons] }
          end

          def triangle_set_overlap(triangles1, triangles2, axis, tolerance)
            polygons = []
            total_area = 0.0
            Array(triangles1).each do |triangle1|
              polygon1 = Utils::Geometry.project_points_for_axis(triangle1, axis)
              Array(triangles2).each do |triangle2|
                polygon2 = Utils::Geometry.project_points_for_axis(triangle2, axis)
                overlap = Utils::Geometry.intersect_polygons_2d(polygon1, polygon2)
                next if overlap.length < 3

                area = Utils::Geometry.polygon_area_2d_value(overlap).abs
                next if area <= Utils::Geometry.area_tolerance(tolerance)

                polygons << overlap
                total_area += area
              end
            end
            { area: total_area, polygons: polygons }
          end

          def model_solid_intersection_for_pair(group1, group2, cell_id1, cell_id2)
            key = pair_key(cell_id1, cell_id2)
            overlap_tolerance_point_cache.delete(key)
            @current_intersection_cell_ids = [cell_id1, cell_id2]
            result = model_solid_intersection(group1, group2)
            apply_explicit_overlap_tolerance_to_pair_result(
              result, group1, group2, key
            )
          ensure
            @current_intersection_cell_ids = nil
            overlap_tolerance_point_cache.delete(key) if defined?(key) && key
          end

          def model_solid_intersection(group1, group2)
            model = @model || Sketchup.active_model
            return { status: :inconclusive, reason: 'BOOLEAN_OPERATION_FAILED' } unless model

            copy1 = nil
            copy2 = nil
            result = nil
            @indoor_model.with_indoor_model_operation(
              'IndoorGML full overlap confirmation', rollback: true
            ) do
              next({ status: :inconclusive, reason: 'INPUT_NOT_MANIFOLD' }) unless
                valid_manifold_group?(group1) && valid_manifold_group?(group2)

              copy1 = build_boolean_copy(group1)
              copy2 = build_boolean_copy(group2)
              next({ status: :inconclusive, reason: 'BOOLEAN_COPY_FAILED' }) unless
                copy1 && copy2
              next({ status: :inconclusive, reason: 'BOOLEAN_COPY_NOT_MANIFOLD' }) unless
                valid_manifold_group?(copy1) && valid_manifold_group?(copy2)
              next({ status: :inconclusive, reason: 'BOOLEAN_OPERATION_FAILED' }) unless
                copy1.respond_to?(:intersect)

              result = copy1.intersect(copy2)
              next({ status: :inconclusive, reason: 'BOOLEAN_OPERATION_FAILED' }) if
                result.nil?

              faces = result.definition.entities.grep(Sketchup::Face).select(&:valid?)
              edges = result.definition.entities.grep(Sketchup::Edge).select(&:valid?)
              if faces.empty? && edges.empty?
                next({
                  status: :not_reproduced,
                  reason: 'NO_VALID_INTERSECTION_GROUP_RETURNED',
                  volume: 0.0,
                  component_count: 0
                })
              end
              next non_solid_intersection_result(result, faces, edges) unless
                valid_manifold_group?(result)

              volume = solid_group_volume(result)
              next non_solid_intersection_result(result, faces, edges) unless
                volume&.positive?

              cache_intersection_overlay_geometry(
                result, @current_intersection_cell_ids, volume
              )
              {
                status: :reproduced,
                reason: 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION',
                volume: volume,
                component_count: face_components(faces).length
              }
            end
          rescue StandardError => e
            log("Model CellSpace intersection failed: #{e.class}: #{e.message}")
            {
              status: :inconclusive,
              reason: "BOOLEAN_OPERATION_FAILED: #{e.class}: #{e.message}"
            }
          ensure
            [result, copy1, copy2].compact.each do |entity|
              next if entity.equal?(group1) || entity.equal?(group2)

              entity.erase! if entity.respond_to?(:valid?) && entity.valid?
            rescue StandardError
              nil
            end
          end

          def build_boolean_copy(source)
            parent = source.respond_to?(:parent) ? source.parent : nil
            target_entities = if parent.respond_to?(:entities)
                                parent.entities
                              elsif parent.respond_to?(:add_instance)
                                parent
                              end
            return nil unless target_entities

            EntityCopyHelper.copy_instance(
              source: source,
              target_entities: target_entities,
              transformation: source.transformation,
              convert_to_group: false,
              make_unique: true
            )
          rescue StandardError => e
            log("Model CellSpace Boolean copy failed: #{e.class}: #{e.message}")
            nil
          end

          def valid_manifold_group?(group)
            return false unless group&.valid?
            return false unless group.respond_to?(:manifold?) && group.manifold?

            volume = solid_group_volume(group)
            !volume.nil? && volume.positive?
          rescue StandardError
            false
          end

          def solid_group_volume(group)
            return nil unless group.respond_to?(:volume)

            volume = group.volume
            volume.nil? ? nil : volume.to_f.abs
          rescue StandardError
            nil
          end

          def non_solid_intersection_result(result, faces, edges)
            volume = solid_group_volume(result)
            edge_face_counts = edges.map do |edge|
              Array(edge.respond_to?(:faces) ? edge.faces : []).count do |face|
                face&.valid?
              end
            rescue StandardError
              0
            end
            boundary_edge_count = edge_face_counts.count(1)
            nonmanifold_edge_count = edge_face_counts.count { |count| count > 2 }
            lower_dimensional = !faces.empty? &&
                                (volume.nil? || volume <= 0.0) &&
                                boundary_edge_count.positive? &&
                                nonmanifold_edge_count.zero?

            {
              status: :non_solid,
              reason: 'NON_SOLID_INTERSECTION_RESULT',
              volume: volume,
              component_count: face_components(faces).length,
              face_count: faces.length,
              edge_count: edges.length,
              boundary_edge_count: boundary_edge_count,
              nonmanifold_edge_count: nonmanifold_edge_count,
              lower_dimensional: lower_dimensional,
              face_points: intersection_face_points(result, faces)
            }
          end

          def resolve_non_solid_intersection(intersection, adjacency_candidates)
            return intersection unless intersection[:status] == :non_solid

            candidates = Array(adjacency_candidates)
            if lower_dimensional_boundary_contact?(intersection, candidates)
              return intersection.merge(
                status: :not_reproduced,
                reason: 'BOUNDARY_CONTACT_ONLY',
                volume: 0.0
              )
            end

            intersection.merge(
              status: :inconclusive,
              reason: 'BOOLEAN_INTERSECTION_INCONCLUSIVE'
            )
          end

          def lower_dimensional_boundary_contact?(intersection, candidates)
            return false unless intersection[:lower_dimensional] == true
            return false if candidates.empty?

            points = Array(intersection[:face_points])
            return false if points.empty?

            points.all? do |point|
              candidates.any? do |candidate|
                point_plane_distance(
                  point, candidate[:normal], candidate[:plane1]
                ) <= @tolerance
              end
            end
          end

          def point_plane_distance(point, normal, plane_constant)
            return Float::INFINITY unless point && normal && !plane_constant.nil?

            value = normal.x.to_f * point.x.to_f +
                    normal.y.to_f * point.y.to_f +
                    normal.z.to_f * point.z.to_f
            (value - plane_constant.to_f).abs
          rescue StandardError
            Float::INFINITY
          end

          def intersection_face_points(result, faces)
            transform = result.transformation
            faces.flat_map do |face|
              face.vertices.map do |vertex|
                vertex.position.transform(transform)
              end
            end.uniq { |point| [point.x.to_f, point.y.to_f, point.z.to_f] }
          rescue StandardError
            []
          end

          def cache_intersection_overlay_geometry(result, cell_ids, volume)
            capture_overlap_tolerance_intersection_points(result, cell_ids)
            return false if Array(cell_ids).any? { |cell_id| cell_id.to_s.empty? }

            transform = Utils::Transformation.root_transformation_in_model(
              @indoor_model&.primal_group
            ) * result.transformation
            geometry = intersection_overlay_geometry(result, transform)
            return false if geometry[:triangles].empty?

            ValidationErrorGeometryResolver.store_overlap_geometry(
              model: @model || Sketchup.active_model,
              cell_ids: cell_ids,
              geometry: {
                status: :ready,
                triangles: geometry[:triangles],
                edges: geometry[:edges],
                volume_in3: volume
              }
            )
          rescue StandardError => e
            log("Overlap overlay cache failed: #{e.class}: #{e.message}")
            false
          end

          def capture_overlap_tolerance_intersection_points(result, cell_ids)
            ids = Array(cell_ids)
            return false unless ids.length == 2
            return false if ids.any? { |cell_id| cell_id.to_s.empty? }
            return false unless result&.valid?

            faces = result.definition.entities.grep(Sketchup::Face).select(&:valid?)
            points = intersection_face_points(result, faces)
            return false if points.empty?

            overlap_tolerance_point_cache[pair_key(ids[0], ids[1])] = points
            true
          rescue StandardError
            false
          end

          def overlap_tolerance_point_cache
            @overlap_tolerance_point_cache ||= {}
          end

          def apply_explicit_overlap_tolerance_to_pair_result(
            result, group1, group2, key
          )
            points = overlap_tolerance_point_cache.delete(key)
            return result unless result.is_a?(Hash)
            return result unless result[:status].to_s == 'reproduced'

            candidates = shared_face_candidates(
              entity_faces(group1), entity_faces(group2)
            )
            resolve_reproduced_intersection_with_overlap_tolerance(
              result, candidates, points
            )
          end

          def resolve_reproduced_intersection_with_overlap_tolerance(
            intersection, candidates, points
          )
            point_list = Array(points)
            candidate_list = Array(candidates)
            return intersection if point_list.empty? || candidate_list.empty?

            match = candidate_list.filter_map do |candidate|
              overlap_tolerance_slab_match(candidate, point_list)
            end.min_by do |row|
              [
                row.fetch(:thickness),
                -row.fetch(:overlap_area),
                row.fetch(:candidate_index)
              ]
            end
            return intersection unless match

            raw_volume = intersection[:volume].to_f
            intersection.merge(
              status: :not_reproduced,
              reason: 'REPRODUCED_INTERSECTION_WITHIN_OVERLAP_TOLERANCE',
              volume: 0.0,
              raw_reproduced_volume: raw_volume,
              overlap_tolerance_gate: {
                applied: true,
                tolerance_in: @tolerance.to_f,
                tolerance_mm: @tolerance.to_f * 25.4,
                measured_thickness_in: match.fetch(:thickness),
                measured_thickness_mm: match.fetch(:thickness) * 25.4,
                candidate_penetration_depth_in: match.fetch(:penetration_depth),
                candidate_penetration_depth_mm:
                  match.fetch(:penetration_depth) * 25.4,
                candidate_overlap_area_in2: match.fetch(:overlap_area),
                candidate_overlap_area_mm2:
                  match.fetch(:overlap_area) * 25.4 * 25.4,
                candidate_index: match.fetch(:candidate_index),
                point_count: point_list.length,
                raw_reproduced_volume_in3: raw_volume,
                raw_reproduced_volume_mm3: raw_volume * 25.4 * 25.4 * 25.4
              }
            )
          end

          def overlap_tolerance_slab_match(candidate, points)
            normal = candidate[:normal]
            plane1 = candidate[:plane1]
            plane2 = candidate[:plane2]
            return nil unless normal && !plane1.nil? && !plane2.nil?

            nx = normal.x.to_f
            ny = normal.y.to_f
            nz = normal.z.to_f
            magnitude = Math.sqrt((nx * nx) + (ny * ny) + (nz * nz))
            return nil if magnitude <= 1.0e-30

            unit = [nx / magnitude, ny / magnitude, nz / magnitude]
            slab1 = plane1.to_f / magnitude
            slab2 = plane2.to_f / magnitude
            slab_min, slab_max = [slab1, slab2].minmax
            penetration_depth = candidate[:penetration_depth].to_f
            return nil if penetration_depth >
                          @tolerance.to_f + overlap_tolerance_numeric_epsilon

            projections = points.map do |point|
              (unit[0] * point.x.to_f) +
                (unit[1] * point.y.to_f) +
                (unit[2] * point.z.to_f)
            end
            return nil if projections.empty?

            epsilon = overlap_tolerance_numeric_epsilon
            return nil unless projections.all? do |value|
              value >= slab_min - epsilon && value <= slab_max + epsilon
            end

            thickness = projections.max - projections.min
            return nil if thickness > @tolerance.to_f + epsilon

            {
              candidate_index: candidate[:face1_index].to_i * 1_000_000 +
                candidate[:face2_index].to_i,
              thickness: thickness,
              penetration_depth: penetration_depth,
              overlap_area: candidate[:overlap_area].to_f
            }
          rescue StandardError
            nil
          end

          def overlap_tolerance_numeric_epsilon
            [@tolerance.to_f.abs * 1.0e-6, 1.0e-10].max
          end

          def intersection_overlay_geometry(group, transform)
            triangles = []
            edges = []
            edge_keys = {}
            group.definition.entities.grep(Sketchup::Face).select(&:valid?).each do |face|
              mesh = face.mesh(0)
              mesh.polygons.each do |polygon|
                points = polygon.map do |index|
                  overlay_world_point(mesh.point_at(index.abs), transform)
                end
                triangles.concat(triangulate_overlay_polygon(points))
              end
              face.edges.each do |edge|
                points = edge.vertices.map do |vertex|
                  overlay_world_point(vertex.position, transform)
                end
                key = points.map { |point| overlay_point_key(point) }.sort
                next if edge_keys[key]

                edge_keys[key] = true
                edges.concat(points)
              end
            end
            { triangles: triangles, edges: edges }
          end

          def triangulate_overlay_polygon(points)
            return [] if points.length < 3
            return [points] if points.length == 3

            (1...(points.length - 1)).map do |index|
              [points[0], points[index], points[index + 1]]
            end
          end

          def overlay_world_point(point, transform)
            transformed = point.transform(transform)
            Geom::Point3d.new(transformed.x, transformed.y, transformed.z)
          end

          def overlay_point_key(point)
            [point.x.to_f.round(8), point.y.to_f.round(8), point.z.to_f.round(8)]
          end

          def face_components(faces)
            remaining = faces.each_with_object({}) { |face, memo| memo[face] = true }
            components = []
            until remaining.empty?
              seed = remaining.keys.first
              stack = [seed]
              component = []
              remaining.delete(seed)
              until stack.empty?
                face = stack.pop
                component << face
                face.edges.flat_map(&:faces).uniq.each do |neighbor|
                  next unless remaining[neighbor]

                  remaining.delete(neighbor)
                  stack << neighbor
                end
              end
              components << component
            end
            components
          end

          def face_pair_signed_distance(face1, face2)
            centroid1 = face_centroid(face1)
            centroid2 = face_centroid(face2)
            return Float::INFINITY unless centroid1 && centroid2

            vector = centroid1.vector_to(centroid2)
            Utils::Geometry.dot_product(vector, face1[:normal]).to_f
          end

          def plane_constant(normal, point)
            Utils::Geometry.dot_product(
              Geom::Vector3d.new(point.x.to_f, point.y.to_f, point.z.to_f),
              normal
            ).to_f
          end

          def face_centroid(face)
            points = Array(face[:points])
            return nil if points.empty?

            Geom::Point3d.new(
              points.sum(&:x) / points.length.to_f,
              points.sum(&:y) / points.length.to_f,
              points.sum(&:z) / points.length.to_f
            )
          end

          def log(message)
            @logger.puts("[IndoorGML] #{message}") if @logger&.respond_to?(:puts)
          end
        end
      end
    end
  end
end
