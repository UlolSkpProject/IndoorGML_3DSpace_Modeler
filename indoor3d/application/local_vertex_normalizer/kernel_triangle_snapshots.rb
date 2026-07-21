# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # Converts SketchUp face meshes to one exact integer-grid triangle
        # complex. SketchUp can occasionally return the same mesh polygon more
        # than once for a merged n-gon with very short boundary segments. An
        # exact duplicate is redundant in a simplicial complex, so retain one
        # canonical triangle and let validate_normalized_triangle_mesh! decide
        # whether the resulting surface is still a closed 2-manifold.
        def normalized_triangle_snapshot(
          entities,
          axis_plane_plan = nil,
          duplicate_diagnostics: nil
        )
          normalize_triangle_records(
            triangle_snapshot(entities),
            axis_plane_plan,
            duplicate_diagnostics: duplicate_diagnostics
          )
        end

        # Captures SketchUp's mesh triangles without applying the normalization
        # grid. Degenerate mesh diagonals must be repaired in this coordinate
        # space first: independently rounding three collinear points can turn a
        # zero-area triangle into a very thin, non-zero triangle.
        def triangle_snapshot(entities)
          entities.grep(@face_class).flat_map do |face|
            mesh = face.mesh(0)
            source_face_key = stable_entity_id(face)
            mesh.polygons.each_with_index.flat_map do |polygon, polygon_index|
              points = polygon.map { |index| mesh.point_at(index.abs) }
              triangulate_polygon(points).map do |triangle_points|
                {
                  points: triangle_points,
                  source_normal: vector_components(face.normal),
                  material: face.material,
                  back_material: face.back_material,
                  layer: face.layer,
                  source_face_key: source_face_key,
                  source_polygon_index: polygon_index
                }
              end
            end
          end
        end

        def normalize_triangle_records(
          triangle_records,
          axis_plane_plan = nil,
          duplicate_diagnostics: nil
        )
          triangles = []
          signatures = {}
          diagnostics = duplicate_diagnostics || {}
          diagnostics[:duplicate_count] = 0
          diagnostics[:samples] = []

          triangle_records.each do |source_record|
            triangle_points = source_record[:points].map do |point|
              normalized_target(point, axis_plane_plan)
            end
            signature = triangle_signature(triangle_points)
            if signatures.key?(signature)
              diagnostics[:duplicate_count] += 1
              if diagnostics[:samples].length < 10
                kept = signatures.fetch(signature)
                diagnostics[:samples] << {
                  signature: signature,
                  kept_face_key: kept[:source_face_key],
                  kept_polygon_index: kept[:source_polygon_index],
                  duplicate_face_key: source_record[:source_face_key],
                  duplicate_polygon_index: source_record[:source_polygon_index]
                }
              end
              next
            end

            record = source_record.merge(points: triangle_points)
            signatures[signature] = record
            triangles << record
          end

          triangles
        end

        # Replaces a zero-area triangle A-B-C (B lies on A-C) together with
        # the non-degenerate triangle A-C-D on the other side of the internal
        # triangulation diagonal. The replacement uses B-D:
        #   (A,B,C) + (A,C,D) -> (A,B,D) + (B,C,D)
        # No vertex is moved or removed.
        def repair_degenerate_source_triangles(
          triangle_records,
          coordinate_space: :grid
        )
          working = triangle_records.map(&:dup)
          repaired_triangles = 0
          replaced_pairs = 0

          loop do
            degenerate_indices = working.each_index.select do |index|
              degenerate_triangle_record?(
                working[index],
                coordinate_space: coordinate_space
              )
            end
            break if degenerate_indices.empty?

            repair = nil
            degenerate_indices.each do |degenerate_index|
              degenerate = working[degenerate_index]
              split = collinear_triangle_split(
                degenerate[:points],
                coordinate_space: coordinate_space
              )
              next unless split

              neighbor_indices = working.each_index.select do |candidate_index|
                next false if candidate_index == degenerate_index

                candidate = working[candidate_index]
                next false unless candidate[:source_face_key] == degenerate[:source_face_key]
                next false if degenerate_triangle_record?(
                  candidate,
                  coordinate_space: coordinate_space
                )

                candidate_keys = candidate[:points].map do |point|
                  triangle_point_key(point, coordinate_space)
                end
                candidate_keys.include?(split[:endpoint_a_key]) &&
                  candidate_keys.include?(split[:endpoint_c_key])
              end

              if neighbor_indices.length > 1
                raise ReconstructionError,
                      "Degenerate triangle has multiple neighbors across its " \
                      "internal diagonal: face=#{degenerate[:source_face_key].inspect} " \
                      "polygon=#{degenerate[:source_polygon_index].inspect} " \
                      "edge=#{[split[:endpoint_a_key], split[:endpoint_c_key]].inspect} " \
                      "neighbors=#{neighbor_indices.inspect}"
              end
              next if neighbor_indices.empty?

              repair = {
                degenerate_index: degenerate_index,
                neighbor_index: neighbor_indices.first,
                split: split
              }
              break
            end

            unless repair
              first_index = degenerate_indices.first
              record = working[first_index]
              raise ReconstructionError,
                    "Could not retriangulate zero-area source triangle: " \
                    "face=#{record[:source_face_key].inspect} " \
                    "polygon=#{record[:source_polygon_index].inspect} " \
                    "points=#{record[:points].map { |point| triangle_point_key(point, coordinate_space) }.inspect}"
            end

            degenerate = working[repair[:degenerate_index]]
            neighbor = working[repair[:neighbor_index]]
            split = repair[:split]
            neighbor_points_by_key = neighbor[:points].each_with_object({}) do |point, points|
              points[triangle_point_key(point, coordinate_space)] = point
            end
            opposite_entry = neighbor_points_by_key.find do |key, _point|
              key != split[:endpoint_a_key] && key != split[:endpoint_c_key]
            end
            unless opposite_entry
              raise ReconstructionError,
                    "Degenerate triangle neighbor has no opposite vertex: " \
                    "#{neighbor[:points].map { |point| triangle_point_key(point, coordinate_space) }.inspect}"
            end
            opposite_point = opposite_entry[1]

            replacements = [
              neighbor.merge(
                points: [split[:endpoint_a], split[:middle], opposite_point],
                source_polygon_index: degenerate[:source_polygon_index]
              ),
              neighbor.merge(
                points: [split[:middle], split[:endpoint_c], opposite_point],
                source_polygon_index: neighbor[:source_polygon_index]
              )
            ]
            replacements.each do |record|
              triangle = record[:points].map do |point|
                triangle_point_key(point, coordinate_space)
              end
              if degenerate_triangle_record?(
                record,
                coordinate_space: coordinate_space
              )
                raise ReconstructionError,
                      "Alternate diagonal still creates a zero-area triangle: " \
                      "#{triangle.inspect}"
              end
            end

            removed_indices = [
              repair[:degenerate_index],
              repair[:neighbor_index]
            ].sort.reverse
            removed_indices.each { |index| working.delete_at(index) }

            existing_signatures = working.each_with_object({}) do |record, signatures|
              signatures[triangle_signature_for_space(
                record[:points],
                coordinate_space
              )] = true
            end
            replacements.each do |record|
              signature = triangle_signature_for_space(
                record[:points],
                coordinate_space
              )
              if existing_signatures.key?(signature)
                raise ReconstructionError,
                      "Alternate diagonal creates duplicate triangle: #{signature.inspect}"
              end

              existing_signatures[signature] = true
              working << record
            end

            repaired_triangles += 1
            replaced_pairs += 1
          end

          [
            working,
            {
              repaired_triangles: repaired_triangles,
              replaced_pairs: replaced_pairs
            }
          ]
        end

        def aggregate_degenerate_repair_reports(stage_reports)
          normalized_stages = stage_reports.transform_values do |report|
            {
              repaired_triangles: report[:repaired_triangles].to_i,
              replaced_pairs: report[:replaced_pairs].to_i
            }
          end

          {
            repaired_triangles: normalized_stages.values.sum do |report|
              report[:repaired_triangles]
            end,
            replaced_pairs: normalized_stages.values.sum do |report|
              report[:replaced_pairs]
            end,
            stages: normalized_stages
          }
        end

        def degenerate_triangle_record?(record, coordinate_space: :grid)
          triangle = record[:points].map do |point|
            triangle_point_key(point, coordinate_space)
          end
          return true if triangle.uniq.length != 3

          if coordinate_space == :source
            !collinear_triangle_split(
              record[:points],
              coordinate_space: :source
            ).nil?
          else
            integer_zero_vector?(integer_triangle_normal(triangle))
          end
        end

        def collinear_triangle_split(points, coordinate_space: :grid)
          keys = points.map { |point| triangle_point_key(point, coordinate_space) }
          return nil unless keys.uniq.length == 3
          if coordinate_space == :grid
            return nil unless integer_zero_vector?(integer_triangle_normal(keys))
          end

          keys.each_index do |middle_index|
            endpoint_indices = keys.each_index.reject { |index| index == middle_index }
            endpoint_a_index, endpoint_c_index = endpoint_indices
            middle_key = keys[middle_index]
            endpoint_a_key = keys[endpoint_a_index]
            endpoint_c_key = keys[endpoint_c_index]
            between = if coordinate_space == :source
                        !point_on_segment_parameter(
                          points[middle_index],
                          points[endpoint_a_index],
                          points[endpoint_c_index],
                          GRID_EPSILON_MM
                        ).nil?
                      else
                        integer_point_between?(
                          middle_key,
                          endpoint_a_key,
                          endpoint_c_key
                        )
                      end
            next unless between

            return {
              endpoint_a: points[endpoint_a_index],
              endpoint_a_key: endpoint_a_key,
              middle: points[middle_index],
              middle_key: middle_key,
              endpoint_c: points[endpoint_c_index],
              endpoint_c_key: endpoint_c_key
            }
          end

          nil
        end

        def triangle_point_key(point, coordinate_space)
          return grid_indices(point) unless coordinate_space == :source

          [point.x.to_f, point.y.to_f, point.z.to_f]
        end

        def triangle_signature_for_space(points, coordinate_space)
          points.map do |point|
            triangle_point_key(point, coordinate_space)
          end.sort
        end

        def integer_point_between?(point, segment_start, segment_end)
          direction = integer_subtract(segment_end, segment_start)
          offset = integer_subtract(point, segment_start)
          return false unless integer_zero_vector?(integer_cross(direction, offset))
          return false if point == segment_start || point == segment_end

          3.times.all? do |axis|
            point[axis] >= [segment_start[axis], segment_end[axis]].min &&
              point[axis] <= [segment_start[axis], segment_end[axis]].max
          end
        end

        def conforming_triangle_snapshot(source_triangles)
          unique_points = {}
          source_triangles.each do |record|
            record[:points].each do |point|
              unique_points[grid_indices(point)] ||= point
            end
          end

          candidates = unique_points.values
          signatures = {}

          source_triangles.flat_map do |record|
            next [] if collinear_triangle?(record[:points])

            boundary = triangle_boundary_with_segment_vertices(
              record[:points],
              candidates
            )

            triangulate_convex_boundary(boundary, candidates).map do |points|
              signature = triangle_signature(points)
              if signatures.key?(signature)
                raise ReconstructionError,
                      "Duplicate conforming triangle detected: #{signature.inspect}"
              end

              signatures[signature] = true
              record.merge(points: points)
            end
          end
        end
      end
    end
  end
end
