# frozen_string_literal: true

require_relative '../utils/geometry/polygon2d_public_api'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityOverlapGeometryRechecker
          def initialize(snapshot_reader:, tolerance:, logger: nil)
            @snapshot_reader = snapshot_reader
            @tolerance = tolerance
            @logger = logger || (defined?(IndoorCore::Logger) && IndoorCore::Logger)
            @pair_analysis = {}
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
            snapshot = @snapshot_reader.read
            cell1 = snapshot[cell_id1]
            cell2 = snapshot[cell_id2]
            if !(cell1 && cell2)
              inconclusive(cell_id1, cell_id2, 'GML_RECONSTRUCTION_FAILED')
            elsif cell1[:unsupported] || cell2[:unsupported]
              inconclusive(cell_id1, cell_id2, 'GML_RECONSTRUCTION_FAILED')
            else
              {
                status: :ok,
                cells: [cell_id1, cell_id2],
                cell1: cell1,
                cell2: cell2,
                adjacency_candidates: shared_face_candidates(cell1[:faces], cell2[:faces], mode: :adjacency),
                overlap_candidates: shared_face_candidates(cell1[:faces], cell2[:faces], mode: :overlap),
                intersection: exported_solid_intersection(cell1, cell2)
              }
            end
          rescue StandardError => e
            inconclusive(cell_id1, cell_id2, "GML_RECONSTRUCTION_FAILED: #{e.class}: #{e.message}")
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

          def shared_face_candidates(faces1, faces2, mode:)
            candidates = []
            faces1.each_with_index do |face1, index1|
              faces2.each_with_index do |face2, index2|
                next if !face1[:interiors].to_a.empty? || !face2[:interiors].to_a.empty?
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
            polygons = []
            total_area = 0.0
            face1[:triangles].each do |triangle1|
              polygon1 = Utils::Geometry.project_points_for_axis(triangle1, axis)
              face2[:triangles].each do |triangle2|
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

          def exported_solid_intersection(cell1, cell2)
            model = Sketchup.active_model
            return { status: :inconclusive, reason: 'BOOLEAN_OPERATION_FAILED' } unless model

            started = false
            group1 = nil
            group2 = nil
            result = nil

            model.start_operation('IndoorGML overlap recheck', true)
            started = true

            group1 = build_temp_solid_group(cell1)
            group2 = build_temp_solid_group(cell2)
            return { status: :inconclusive, reason: 'GML_RECONSTRUCTION_FAILED' } unless group1 && group2
            return { status: :inconclusive, reason: 'INPUT_NOT_MANIFOLD' } unless valid_manifold_group?(group1) && valid_manifold_group?(group2)
            return { status: :inconclusive, reason: 'BOOLEAN_OPERATION_FAILED' } unless group1.respond_to?(:intersect)

            result = group1.intersect(group2)
            return { status: :not_reproduced, reason: 'NO_VALID_INTERSECTION_GROUP_RETURNED', volume: 0.0, component_count: 0 } if result.nil?

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
            log("Exported solid intersection failed: #{e.class}: #{e.message}")
            { status: :inconclusive, reason: "BOOLEAN_OPERATION_FAILED: #{e.class}: #{e.message}" }
          ensure
            model.abort_operation if started
            [result, group1, group2].compact.each do |entity|
              entity.erase! if entity.respond_to?(:valid?) && entity.valid?
            rescue StandardError
              nil
            end
          end

          def build_temp_solid_group(cell)
            group = Sketchup.active_model.entities.add_group
            cell[:faces].each do |face|
              created = group.entities.add_face(face[:points])
              unless created&.valid?
                group.erase! if group.valid?
                return nil
              end
              face[:interiors].to_a.each do |ring|
                inner = group.entities.add_face(ring)
                inner.erase! if inner&.valid?
              end
            end
            group
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
