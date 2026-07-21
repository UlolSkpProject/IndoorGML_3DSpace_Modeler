# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        SOURCE_FACE_BOUNDARY_COMMON_REFINEMENT_TOLERANCE_MM =
          if const_defined?(:STRICT_COPLANAR_TOLERANCE_MM, false)
            STRICT_COPLANAR_TOLERANCE_MM
          else
            0.0001
          end unless const_defined?(
            :SOURCE_FACE_BOUNDARY_COMMON_REFINEMENT_TOLERANCE_MM,
            false
          )
        SOURCE_FACE_BOUNDARY_COMMON_REFINEMENT_MIN_OVERLAP_MM =
          SOURCE_FACE_BOUNDARY_COMMON_REFINEMENT_TOLERANCE_MM unless
            const_defined?(
              :SOURCE_FACE_BOUNDARY_COMMON_REFINEMENT_MIN_OVERLAP_MM,
              false
            )

        private

        # A nearby foreign vertex is not enough evidence that two source Faces
        # share a boundary. Build a common refinement only from boundary Edge pairs
        # whose source-space segments overlap along the same supporting line. The
        # union of both segments' endpoints is then inserted into both ordered Face
        # loops. This changes A-B and A-P/P-B into the same A-P-B subdivision while
        # ignoring isolated vertices that merely happen to be close to A-B.
        def capture_normalized_source_face_constraints(
          entities,
          axis_plane_plan,
          short_edge_plan
        )
          point_targets = short_edge_plan.is_a?(Hash) ?
            Hash(short_edge_plan[:point_targets]) : {}
          inventory = source_boundary_common_refinement_inventory(entities)
          split_entries, relations =
            source_boundary_common_refinement_splits(inventory[:edges])

          constraints = inventory[:faces].each_with_object({}) do |face_record, result|
            face = face_record[:face]
            face_relation_count = 0
            loops = face_record[:loops].map do |loop_record|
              expanded = []
              loop_record[:edge_indices].each do |edge_index|
                edge = inventory[:edges].fetch(edge_index)
                expanded << edge[:first]
                insertions = Array(split_entries[edge_index])
                face_relation_count += insertions.length
                insertions.each { |entry| expanded << entry[:point_entry] }
              end
              expanded = source_boundary_compact_point_entries(expanded)

              points = expanded.map do |entry|
                normalized = normalized_target(entry[:point], axis_plane_plan)
                point_targets[grid_indices(normalized)] || normalized
              end
              {
                outer: loop_record[:outer],
                points: points
              }
            end
            next if loops.empty?

            result[face_record[:face_key]] = {
              source_face_key: face_record[:face_key],
              source_normal: vector_components(face.normal),
              material: face.material,
              back_material: face.back_material,
              layer: face.layer,
              loops: loops,
              boundary_subdivision_count: face_relation_count
            }
          end

          @source_face_boundary_subdivision_report = {
            relation_count: relations.length,
            face_count: relations.map { |entry| entry[:face_key] }.uniq.length,
            inserted_source_point_count:
              relations.map { |entry| entry[:inserted_source_key] }.uniq.length,
            max_source_distance_mm:
              relations.map { |entry| entry[:source_distance_mm] }.max || 0.0,
            overlap_pair_count:
              relations.map { |entry| entry[:overlap_pair_key] }.uniq.length,
            min_overlap_length_mm:
              relations.map { |entry| entry[:overlap_length_mm] }.min || 0.0,
            relations: relations.first(100)
          }
          constraints
        end

        def source_boundary_common_refinement_inventory(entities)
          points = {}
          faces = []
          edges = []

          entities.grep(@face_class).each do |face|
            next unless face&.valid?

            face_key = stable_entity_id(face)
            outer_loop = face.respond_to?(:outer_loop) ? face.outer_loop : nil
            loops = Array(face.respond_to?(:loops) ? face.loops : []).map.with_index do |loop, loop_index|
              entries = loop.vertices.map do |vertex|
                point = vertex.position
                key = source_point_key(point)
                entry = points[key] ||= {
                  source_key: key,
                  point: point,
                  point_mm: point_components_mm(point),
                  face_keys: {}
                }
                entry[:face_keys][face_key] = true
                entry
              end
              edge_indices = entries.each_index.map do |edge_index|
                index = edges.length
                edges << {
                  edge_index: index,
                  face_key: face_key,
                  loop_index: loop_index,
                  loop_edge_index: edge_index,
                  first: entries[edge_index],
                  second: entries[(edge_index + 1) % entries.length]
                }
                index
              end
              {
                outer: loop.equal?(outer_loop),
                edge_indices: edge_indices
              }
            end
            faces << {
              face: face,
              face_key: face_key,
              loops: loops
            } unless loops.empty?
          end

          { points: points, faces: faces, edges: edges }
        end

        def source_boundary_common_refinement_splits(edges)
          raw_splits = Hash.new { |hash, key| hash[key] = [] }
          relations = []

          source_boundary_common_refinement_candidate_pairs(edges).each do |first_index, second_index|
            first_edge = edges.fetch(first_index)
            second_edge = edges.fetch(second_index)
            next if first_edge[:face_key] == second_edge[:face_key]

            overlap = source_boundary_edge_overlap_analysis(first_edge, second_edge)
            next unless overlap

            pair_key = [first_index, second_index].sort
            source_boundary_add_overlap_endpoint_splits(
              first_edge,
              second_edge,
              overlap,
              pair_key,
              raw_splits,
              relations
            )
            source_boundary_add_overlap_endpoint_splits(
              second_edge,
              first_edge,
              overlap,
              pair_key,
              raw_splits,
              relations
            )
          end

          compact = raw_splits.transform_values do |entries|
            best_by_source_key = {}
            entries.each do |entry|
              key = entry[:point_entry][:source_key]
              current = best_by_source_key[key]
              if current.nil? ||
                 ([entry[:source_distance_mm], entry[:source_parameter]] <=>
                   [current[:source_distance_mm], current[:source_parameter]]) == -1
                best_by_source_key[key] = entry
              end
            end
            best_by_source_key.values.sort_by do |entry|
              [
                entry[:source_parameter],
                entry[:source_distance_mm],
                entry[:point_entry][:source_key]
              ]
            end
          end

          compact_relation_keys = {}
          compact_relations = relations.each_with_object([]) do |entry, result|
            key = [
              entry[:host_edge_index],
              entry[:inserted_source_key]
            ]
            next if compact_relation_keys[key]

            compact_relation_keys[key] = true
            result << entry
          end
          [compact, compact_relations]
        end

        def source_boundary_common_refinement_candidate_pairs(edges)
          return [] if edges.length < 2

          tolerance = SOURCE_FACE_BOUNDARY_COMMON_REFINEMENT_TOLERANCE_MM
          spans = 3.times.map do |axis|
            values = edges.flat_map do |edge|
              [edge[:first][:point_mm][axis], edge[:second][:point_mm][axis]]
            end
            minimum, maximum = values.minmax
            maximum - minimum
          end
          sweep_axis = spans.each_index.max_by { |axis| spans[axis] }
          ordered = edges.each_index.sort_by do |index|
            edge = edges[index]
            [
              [edge[:first][:point_mm][sweep_axis], edge[:second][:point_mm][sweep_axis]].min,
              index
            ]
          end

          active = []
          pairs = []
          ordered.each do |index|
            edge = edges[index]
            current_min = [
              edge[:first][:point_mm][sweep_axis],
              edge[:second][:point_mm][sweep_axis]
            ].min
            active.reject! do |other_index|
              other = edges[other_index]
              other_max = [
                other[:first][:point_mm][sweep_axis],
                other[:second][:point_mm][sweep_axis]
              ].max
              other_max < (current_min - tolerance)
            end
            active.each do |other_index|
              other = edges[other_index]
              next unless source_boundary_edge_aabbs_overlap?(edge, other, tolerance)

              pairs << [other_index, index]
            end
            active << index
          end
          pairs
        end

        def source_boundary_edge_aabbs_overlap?(first_edge, second_edge, tolerance)
          3.times.all? do |axis|
            first_range = [
              first_edge[:first][:point_mm][axis],
              first_edge[:second][:point_mm][axis]
            ].minmax
            second_range = [
              second_edge[:first][:point_mm][axis],
              second_edge[:second][:point_mm][axis]
            ].minmax
            first_range[0] <= (second_range[1] + tolerance) &&
              second_range[0] <= (first_range[1] + tolerance)
          end
        end

        def source_boundary_edge_overlap_analysis(first_edge, second_edge)
          tolerance = SOURCE_FACE_BOUNDARY_COMMON_REFINEMENT_TOLERANCE_MM
          minimum_overlap =
            SOURCE_FACE_BOUNDARY_COMMON_REFINEMENT_MIN_OVERLAP_MM
          first_a = first_edge[:first][:point_mm]
          first_b = first_edge[:second][:point_mm]
          second_a = second_edge[:first][:point_mm]
          second_b = second_edge[:second][:point_mm]
          first_length = source_boundary_point_distance_mm(first_a, first_b)
          second_length = source_boundary_point_distance_mm(second_a, second_b)
          return nil if first_length <= minimum_overlap ||
                        second_length <= minimum_overlap

          distances = [
            source_boundary_point_line_distance_mm(second_a, first_a, first_b),
            source_boundary_point_line_distance_mm(second_b, first_a, first_b),
            source_boundary_point_line_distance_mm(first_a, second_a, second_b),
            source_boundary_point_line_distance_mm(first_b, second_a, second_b)
          ]
          return nil if distances.any? { |distance| distance > tolerance }

          first_parameters = [
            source_boundary_segment_parameter(second_a, first_a, first_b),
            source_boundary_segment_parameter(second_b, first_a, first_b)
          ]
          overlap_start = [0.0, first_parameters.min].max
          overlap_end = [1.0, first_parameters.max].min
          overlap_length = (overlap_end - overlap_start) * first_length
          return nil unless overlap_length > minimum_overlap

          {
            overlap_length_mm: overlap_length,
            max_source_distance_mm: distances.max || 0.0
          }
        end

        def source_boundary_add_overlap_endpoint_splits(
          host_edge,
          contributor_edge,
          overlap,
          pair_key,
          raw_splits,
          relations
        )
          tolerance = SOURCE_FACE_BOUNDARY_COMMON_REFINEMENT_TOLERANCE_MM
          host_first = host_edge[:first][:point_mm]
          host_second = host_edge[:second][:point_mm]
          host_length = source_boundary_point_distance_mm(host_first, host_second)
          return unless host_length.positive?

          [contributor_edge[:first], contributor_edge[:second]].each do |candidate|
            next if candidate[:source_key] == host_edge[:first][:source_key] ||
                    candidate[:source_key] == host_edge[:second][:source_key]

            distance, parameter =
              source_boundary_point_segment_distance_and_parameter_mm(
                candidate[:point_mm],
                host_first,
                host_second
              )
            next unless parameter && parameter.positive? && parameter < 1.0
            next if distance > tolerance
            next if (parameter * host_length) <= tolerance
            next if ((1.0 - parameter) * host_length) <= tolerance

            entry = {
              point_entry: candidate,
              source_parameter: parameter,
              source_distance_mm: distance,
              overlap_length_mm: overlap[:overlap_length_mm],
              overlap_pair_key: pair_key
            }
            raw_splits[host_edge[:edge_index]] << entry
            relations << {
              face_key: host_edge[:face_key],
              loop_index: host_edge[:loop_index],
              edge_first_source_key: host_edge[:first][:source_key],
              edge_second_source_key: host_edge[:second][:source_key],
              inserted_source_key: candidate[:source_key],
              inserted_source_face_keys: candidate[:face_keys].keys.sort,
              contributor_face_key: contributor_edge[:face_key],
              contributor_edge_index: contributor_edge[:edge_index],
              host_edge_index: host_edge[:edge_index],
              source_distance_mm: distance,
              source_parameter: parameter,
              overlap_length_mm: overlap[:overlap_length_mm],
              overlap_pair_key: pair_key
            }
          end
        end

        def source_boundary_compact_point_entries(entries)
          compact = []
          entries.each do |entry|
            compact << entry if compact.empty? ||
              compact.last[:source_key] != entry[:source_key]
          end
          compact.pop if compact.length > 1 &&
            compact.first[:source_key] == compact.last[:source_key]
          compact
        end

        def source_boundary_point_segment_distance_and_parameter_mm(point, first, second)
          direction = 3.times.map { |axis| second[axis] - first[axis] }
          length_squared = direction.sum { |value| value * value }
          return [Float::INFINITY, nil] unless length_squared.positive?

          offset = 3.times.map { |axis| point[axis] - first[axis] }
          parameter = 3.times.sum do |axis|
            offset[axis] * direction[axis]
          end / length_squared
          closest = 3.times.map do |axis|
            first[axis] + (parameter * direction[axis])
          end
          [source_boundary_point_distance_mm(point, closest), parameter]
        end

        def source_boundary_segment_parameter(point, first, second)
          direction = 3.times.map { |axis| second[axis] - first[axis] }
          length_squared = direction.sum { |value| value * value }
          return 0.0 unless length_squared.positive?

          offset = 3.times.map { |axis| point[axis] - first[axis] }
          3.times.sum { |axis| offset[axis] * direction[axis] } /
            length_squared
        end

        def source_boundary_point_line_distance_mm(point, first, second)
          direction = 3.times.map { |axis| second[axis] - first[axis] }
          offset = 3.times.map { |axis| point[axis] - first[axis] }
          length = Math.sqrt(direction.sum { |value| value * value })
          return Float::INFINITY unless length.positive?

          cross = [
            (offset[1] * direction[2]) - (offset[2] * direction[1]),
            (offset[2] * direction[0]) - (offset[0] * direction[2]),
            (offset[0] * direction[1]) - (offset[1] * direction[0])
          ]
          Math.sqrt(cross.sum { |value| value * value }) / length
        end

        def source_boundary_point_distance_mm(first, second)
          Math.sqrt(
            3.times.sum do |axis|
              delta = first[axis] - second[axis]
              delta * delta
            end
          )
        end
      end
    end
  end
end
