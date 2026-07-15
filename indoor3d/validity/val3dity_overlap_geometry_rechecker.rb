# frozen_string_literal: true

require_relative '../utils/geometry'
require_relative '../infrastructure/scene/entity_copy_helper'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityOverlapGeometryRechecker
          def initialize(indoor_model:, tolerance:, model: nil, logger: nil)
            @indoor_model = indoor_model
            @tolerance = tolerance
            @model = model || indoor_model&.model
            @logger = logger || (defined?(IndoorCore::Logger) && IndoorCore::Logger)
            @pair_analysis = {}
            @cell_geometry = {}
            @cell_spaces_by_report_id = nil
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
            direction = code == 701 ? 'SketchUp Boolean non-reproduction' : 'near-coplanar shared-face adjacency'
            "opposite-normal face pair has signed #{direction} distance within #{@tolerance * 25.4} mm"
          end

          private

          def analyze_pair(cell_id1, cell_id2)
            cell1 = model_cell_geometry(cell_id1)
            return inconclusive(cell_id1, cell_id2, cell1[:reason]) unless cell1[:status] == :ok

            cell2 = model_cell_geometry(cell_id2)
            return inconclusive(cell_id1, cell_id2, cell2[:reason]) unless cell2[:status] == :ok

            {
              status: :ok,
              cells: [cell_id1, cell_id2],
              cell1: cell1,
              cell2: cell2,
              adjacency_candidates: shared_face_candidates(cell1[:faces], cell2[:faces], mode: :adjacency),
              overlap_candidates: shared_face_candidates(cell1[:faces], cell2[:faces], mode: :overlap),
              intersection: model_solid_intersection(cell1[:entity], cell2[:entity])
            }
          rescue StandardError => e
            inconclusive(cell_id1, cell_id2, "MODEL_GEOMETRY_RECHECK_FAILED: #{e.class}: #{e.message}")
          end

          def inconclusive(cell_id1, cell_id2, reason)
            {
              status: :inconclusive,
              cells: [cell_id1, cell_id2],
              reason: reason
            }
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

          def shared_face_candidates(faces1, faces2, mode:)
            candidates = []
            faces1.each_with_index do |face1, index1|
              faces2.each_with_index do |face2, index2|
                next unless Utils::Geometry.normals_opposite?(face1[:normal], face2[:normal])

                distance = face_pair_signed_distance(face1, face2)
                next unless distance.abs <= @tolerance
                next if mode == :overlap && !distance.negative?

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
            return { area: 0.0, polygons: [] } if face1[:triangles].empty? || face2[:triangles].empty?

            axis = Utils::Geometry.dominant_axis(face1[:normal])
            outer = triangle_set_overlap(face1[:triangles], face2[:triangles], axis, tolerance)
            removed_by_face1_holes = Array(face1[:interior_triangles]).sum do |hole_triangles|
              triangle_set_overlap(hole_triangles, face2[:triangles], axis, tolerance)[:area]
            end
            removed_by_face2_holes = Array(face2[:interior_triangles]).sum do |hole_triangles|
              triangle_set_overlap(face1[:triangles], hole_triangles, axis, tolerance)[:area]
            end
            restored_double_subtraction = Array(face1[:interior_triangles]).sum do |hole1_triangles|
              Array(face2[:interior_triangles]).sum do |hole2_triangles|
                triangle_set_overlap(hole1_triangles, hole2_triangles, axis, tolerance)[:area]
              end
            end
            area = outer[:area] - removed_by_face1_holes - removed_by_face2_holes + restored_double_subtraction
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

          def model_solid_intersection(group1, group2)
            model = @model || Sketchup.active_model
            return { status: :inconclusive, reason: 'BOOLEAN_OPERATION_FAILED' } unless model

            started = false
            copy1 = nil
            copy2 = nil
            result = nil

            model.start_operation('IndoorGML overlap recheck', true)
            started = true

            return { status: :inconclusive, reason: 'INPUT_NOT_MANIFOLD' } unless valid_manifold_group?(group1) && valid_manifold_group?(group2)
            copy1 = build_boolean_copy(group1)
            copy2 = build_boolean_copy(group2)
            return { status: :inconclusive, reason: 'BOOLEAN_COPY_FAILED' } unless copy1 && copy2
            return { status: :inconclusive, reason: 'BOOLEAN_COPY_NOT_MANIFOLD' } unless valid_manifold_group?(copy1) && valid_manifold_group?(copy2)
            return { status: :inconclusive, reason: 'BOOLEAN_OPERATION_FAILED' } unless copy1.respond_to?(:intersect)

            result = copy1.intersect(copy2)
            return { status: :inconclusive, reason: 'BOOLEAN_OPERATION_FAILED' } if result.nil?

            faces = result.definition.entities.grep(Sketchup::Face).select(&:valid?)
            edges = result.definition.entities.grep(Sketchup::Edge).select(&:valid?)
            return { status: :not_reproduced, reason: 'NO_VALID_INTERSECTION_GROUP_RETURNED', volume: 0.0, component_count: 0 } if faces.empty? && edges.empty?
            return { status: :inconclusive, reason: 'INVALID_INTERSECTION_RESULT' } unless valid_manifold_group?(result)

            volume = solid_group_volume(result)
            return { status: :inconclusive, reason: 'INVALID_INTERSECTION_RESULT' } if volume.nil? || volume <= 0.0

            {
              status: :reproduced,
              reason: 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION',
              volume: volume,
              component_count: face_components(faces).length
            }
          rescue StandardError => e
            log("Model CellSpace intersection failed: #{e.class}: #{e.message}")
            { status: :inconclusive, reason: "BOOLEAN_OPERATION_FAILED: #{e.class}: #{e.message}" }
          ensure
            model.abort_operation if started
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
            !volume.nil? && volume > 0.0
          rescue StandardError
            false
          end

          def solid_group_volume(group)
            return nil unless group.respond_to?(:volume)

            volume = group.volume
            return nil if volume.nil?

            volume.to_f.abs
          rescue StandardError
            nil
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
