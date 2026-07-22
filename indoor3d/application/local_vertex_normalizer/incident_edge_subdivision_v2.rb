# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(
          :repair_degenerate_source_triangles_before_incident_edge_subdivision_v2
        )
          alias_method(
            :repair_degenerate_source_triangles_before_incident_edge_subdivision_v2,
            :repair_degenerate_source_triangles
          )
        end

        # SketchUp can triangulate a valid Face so that one mesh triangle becomes
        # approximately zero-area after normalization. The legacy repair first
        # tries a same-Face diagonal flip. When that is impossible because the
        # collinear triangle's long edge is a real Face boundary, insert the middle
        # vertex into every non-degenerate triangle incident to that long edge.
        #
        #   degenerate: (A, B, C), B lies on A-C
        #   incident:   (A, C, D)
        #   replacement:(A, B, D) + (B, C, D)
        #
        # The operation is source-Face agnostic. It acts on the complete in-memory
        # triangle complex and validates each subdivision's boundary, orientation,
        # degeneracy, and duplicate constraints before accepting it.
        def repair_degenerate_source_triangles(
          triangle_records,
          coordinate_space: :grid
        )
          return repair_degenerate_source_triangles_before_incident_edge_subdivision_v2(
            triangle_records,
            coordinate_space: coordinate_space
          ) unless coordinate_space == :source

          working = triangle_records.map(&:dup)
          subdivision_count = 0
          subdivided_triangle_count = 0
          subdivision_samples = []
          last_legacy_error = nil

          loop do
            begin
              repaired, report =
                repair_degenerate_source_triangles_before_runtime_regression_v2(
                  working,
                  coordinate_space: :source
                )
              return [
                repaired,
                augment_incident_edge_subdivision_report_v2(
                  report,
                  subdivision_count,
                  subdivided_triangle_count,
                  subdivision_samples,
                  last_legacy_error
                )
              ]
            rescue ReconstructionError => error
              last_legacy_error = error
            end

            repair = incident_edge_subdivision_repair_v2(working)
            unless repair
              sanitized, report =
                repair_degenerate_source_triangles_before_incident_edge_subdivision_v2(
                  working,
                  coordinate_space: :source
                )
              return [
                sanitized,
                augment_incident_edge_subdivision_report_v2(
                  report,
                  subdivision_count,
                  subdivided_triangle_count,
                  subdivision_samples,
                  last_legacy_error
                )
              ]
            end

            working = repair.fetch(:records)
            subdivision_count += 1
            subdivided_triangle_count += repair.fetch(:incident_triangle_count)
            subdivision_samples << repair.fetch(:sample) if
              subdivision_samples.length < 20
          end
        end

        def incident_edge_subdivision_repair_v2(triangle_records)
          triangle_records.each_index do |degenerate_index|
            degenerate = triangle_records[degenerate_index]
            next unless degenerate_triangle_record?(
              degenerate,
              coordinate_space: :source
            )

            split = collinear_triangle_split(
              degenerate[:points],
              coordinate_space: :source
            )
            next unless split

            incident_indices = triangle_records.each_index.select do |candidate_index|
              next false if candidate_index == degenerate_index

              candidate = triangle_records[candidate_index]
              next false if degenerate_triangle_record?(
                candidate,
                coordinate_space: :source
              )

              candidate_keys = candidate[:points].map do |point|
                triangle_point_key(point, :source)
              end
              candidate_keys.include?(split[:endpoint_a_key]) &&
                candidate_keys.include?(split[:endpoint_c_key])
            end
            next if incident_indices.empty?

            repair = build_incident_edge_subdivision_v2(
              triangle_records,
              degenerate_index,
              incident_indices,
              split
            )
            return repair if repair
          end

          nil
        end

        def build_incident_edge_subdivision_v2(
          triangle_records,
          degenerate_index,
          incident_indices,
          split
        )
          replacements = []
          incident_indices.each do |incident_index|
            pair = subdivide_incident_triangle_record_v2(
              triangle_records[incident_index],
              split
            )
            return nil unless pair

            replacements.concat(pair)
          end

          removed_lookup = ([degenerate_index] + incident_indices).to_h do |index|
            [index, true]
          end
          unchanged = triangle_records.each_with_index.filter_map do |record, index|
            record unless removed_lookup[index]
          end

          signatures = {}
          unchanged.each do |record|
            signature = triangle_signature_for_space(record[:points], :source)
            signatures[signature] = true
          end
          replacements.each do |record|
            signature = triangle_signature_for_space(record[:points], :source)
            return nil if signatures.key?(signature)

            signatures[signature] = true
          end

          degenerate = triangle_records[degenerate_index]
          {
            records: unchanged + replacements,
            incident_triangle_count: incident_indices.length,
            sample: {
              degenerate_face_key: degenerate[:source_face_key],
              degenerate_polygon_index: degenerate[:source_polygon_index],
              endpoint_a: split[:endpoint_a_key],
              middle: split[:middle_key],
              endpoint_c: split[:endpoint_c_key],
              incident_face_keys: incident_indices.map do |index|
                triangle_records[index][:source_face_key]
              end,
              incident_polygon_indices: incident_indices.map do |index|
                triangle_records[index][:source_polygon_index]
              end
            }
          }
        end

        def subdivide_incident_triangle_record_v2(record, split)
          points = record[:points]
          keys = points.map { |point| triangle_point_key(point, :source) }
          endpoint_a_index = keys.index(split[:endpoint_a_key])
          endpoint_c_index = keys.index(split[:endpoint_c_key])
          return nil unless endpoint_a_index && endpoint_c_index

          start_index, end_index =
            if (endpoint_a_index + 1) % 3 == endpoint_c_index
              [endpoint_a_index, endpoint_c_index]
            elsif (endpoint_c_index + 1) % 3 == endpoint_a_index
              [endpoint_c_index, endpoint_a_index]
            end
          return nil unless start_index && end_index

          opposite_index = (0...3).find do |index|
            index != start_index && index != end_index
          end
          return nil unless opposite_index

          start_point = points[start_index]
          end_point = points[end_index]
          middle_point = split[:middle]
          opposite_point = points[opposite_index]

          replacements = [
            record.merge(
              points: [start_point, middle_point, opposite_point],
              incident_edge_subdivision_part: 0
            ),
            record.merge(
              points: [middle_point, end_point, opposite_point],
              incident_edge_subdivision_part: 1
            )
          ]
          return nil if replacements.any? do |replacement|
            degenerate_triangle_record?(
              replacement,
              coordinate_space: :source
            )
          end
          return nil unless incident_subdivision_orientation_preserved_v2?(
            record,
            replacements
          )
          return nil unless incident_subdivision_boundary_preserved_v2?(
            record,
            replacements,
            split
          )

          replacements
        end

        def incident_subdivision_orientation_preserved_v2?(source, replacements)
          source_normal = source_triangle_normal_v2(source[:points])
          return false if vector_length(source_normal) <= 0.0

          replacements.all? do |replacement|
            normal = source_triangle_normal_v2(replacement[:points])
            vector_length(normal) > 0.0 &&
              vector_dot(source_normal, normal).positive?
          end
        end

        def source_triangle_normal_v2(points)
          coordinates = points.map do |point|
            [point.x.to_f, point.y.to_f, point.z.to_f]
          end
          first = coordinates[0]
          second = coordinates[1]
          third = coordinates[2]
          integer_cross(
            second.each_index.map { |axis| second[axis] - first[axis] },
            third.each_index.map { |axis| third[axis] - first[axis] }
          )
        end

        def incident_subdivision_boundary_preserved_v2?(
          source,
          replacements,
          split
        )
          long_edge = canonical_edge_key(
            split[:endpoint_a_key],
            split[:endpoint_c_key]
          )
          split_edges = [
            canonical_edge_key(split[:endpoint_a_key], split[:middle_key]),
            canonical_edge_key(split[:middle_key], split[:endpoint_c_key])
          ]

          source_keys = source[:points].map do |point|
            triangle_point_key(point, :source)
          end
          expected_boundary = 3.times.flat_map do |edge_index|
            edge = canonical_edge_key(
              source_keys[edge_index],
              source_keys[(edge_index + 1) % 3]
            )
            edge == long_edge ? split_edges : [edge]
          end.sort

          edge_owners = Hash.new(0)
          replacements.each do |replacement|
            keys = replacement[:points].map do |point|
              triangle_point_key(point, :source)
            end
            3.times do |edge_index|
              edge = canonical_edge_key(
                keys[edge_index],
                keys[(edge_index + 1) % 3]
              )
              edge_owners[edge] += 1
            end
          end
          return false unless edge_owners.values.all? { |owners| [1, 2].include?(owners) }

          actual_boundary = edge_owners.filter_map do |edge, owners|
            edge if owners == 1
          end.sort
          return false unless actual_boundary == expected_boundary

          opposite_key = source_keys.find do |key|
            key != split[:endpoint_a_key] && key != split[:endpoint_c_key]
          end
          return false unless opposite_key

          internal_edges = edge_owners.filter_map do |edge, owners|
            edge if owners == 2
          end
          internal_edges == [
            canonical_edge_key(split[:middle_key], opposite_key)
          ]
        end

        def augment_incident_edge_subdivision_report_v2(
          report,
          subdivision_count,
          subdivided_triangle_count,
          samples,
          legacy_error
        )
          augmented = report.dup
          augmented[:repaired_triangles] =
            augmented[:repaired_triangles].to_i + subdivision_count
          augmented[:incident_edge_subdivision_count] = subdivision_count
          augmented[:incident_edge_subdivided_triangle_count] =
            subdivided_triangle_count
          augmented[:incident_edge_subdivision_samples] = samples
          if legacy_error && subdivision_count.positive?
            augmented[:incident_edge_subdivision_trigger] =
              "#{legacy_error.class}: #{legacy_error.message}"
          end
          augmented
        end
      end
    end
  end
end
