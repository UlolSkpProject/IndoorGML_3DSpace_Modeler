# frozen_string_literal: true

# Phase 1 read-only feasibility probe for polygon-preserving LVN.
#
# This script never modifies SketchUp geometry and never calls the production
# LocalVertexNormalizer. It snapshots definition-local polygon topology, simulates
# 0.001 mm grid snapping, and reports whether the original Face loops could be
# preserved without heuristic repair.
#
# Default: first selected Group / ComponentInstance only.
#
#   ULOL::Indoor3DGmlModeler::IndoorCore::
#     LvnPolygonPreservingFeasibilityProbe.run(mode: :first)
#
# Representative face-count quantiles:
#
#   ULOL::Indoor3DGmlModeler::IndoorCore::
#     LvnPolygonPreservingFeasibilityProbe.run(
#       mode: :quantiles,
#       sample_count: 12
#     )
#
# All selected solids:
#
#   ULOL::Indoor3DGmlModeler::IndoorCore::
#     LvnPolygonPreservingFeasibilityProbe.run(mode: :all)

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonPreservingFeasibilityProbe
        DEFAULT_TOLERANCE_MM = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
        PLANARITY_TOLERANCE_MM =
          LocalVertexNormalizer::STRICT_COPLANAR_TOLERANCE_MM
        MM_PER_INCH = LocalVertexNormalizer::MM_PER_INCH
        MAX_UNSAFE_FACE_SAMPLES = 12

        module_function

        def run(mode: :first, sample_count: 12)
          model = Sketchup.active_model
          selected = selected_entities(model)
          if selected.empty?
            puts '[LVN POLYGON PROBE] Select one or more Group / ComponentInstance solids first.'
            return false
          end

          targets = select_targets(selected, mode, sample_count)
          puts '=' * 92
          puts ' LVN Polygon-Preserving Feasibility Probe — Phase 1 (Read Only)'
          puts '=' * 92
          puts format('selected solids       : %d', selected.length)
          puts format('tested solids         : %d', targets.length)
          puts format('mode                  : %s', mode)
          puts format('grid tolerance        : %.6f mm', DEFAULT_TOLERANCE_MM)
          puts format('planarity tolerance   : %.6f mm', PLANARITY_TOLERANCE_MM)
          puts 'coordinate space      : definition local'
          puts 'geometry mutations    : none'
          puts 'production LVN calls  : none'

          results = []
          targets.each_with_index do |entity, index|
            puts '-' * 92
            puts format(
              '[%02d/%02d] %s',
              index + 1,
              targets.length,
              entity_label(entity)
            )
            result = analyze_entity(entity)
            results << result
            print_entity_result(result)
          rescue StandardError => error
            result = {
              label: entity_label(entity),
              status: :error,
              error: "#{error.class}: #{error.message}",
              backtrace: Array(error.backtrace).first(6)
            }
            results << result
            warn "[LVN POLYGON PROBE] #{result[:label]} #{result[:error]}"
            result[:backtrace].each { |line| warn "  #{line}" }
          end

          print_summary(results)
          results.none? { |result| result[:status] == :error }
        rescue StandardError => error
          warn "[LVN POLYGON PROBE] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(8).join("\n")
          false
        end

        def selected_entities(model)
          model.selection.to_a.select do |entity|
            entity.respond_to?(:definition) &&
              entity.respond_to?(:valid?) &&
              entity.valid?
          end
        end

        def select_targets(selected, mode, sample_count)
          case mode.to_sym
          when :first
            [selected.first]
          when :all
            selected
          when :quantiles
            quantile_sample(selected, sample_count)
          else
            raise ArgumentError, "Unknown probe mode: #{mode.inspect}"
          end
        end

        def quantile_sample(entities, sample_count)
          count = [[sample_count.to_i, 1].max, entities.length].min
          sorted = entities.sort_by do |entity|
            [
              entity.definition.entities.grep(Sketchup::Face).length,
              persistent_id(entity).to_i,
              entity.object_id
            ]
          end
          return sorted if count >= sorted.length
          return [sorted.first] if count == 1

          indices = count.times.map do |index|
            ((index.to_f * (sorted.length - 1)) / (count - 1)).round
          end.uniq
          indices.map { |index| sorted[index] }
        end

        def analyze_entity(entity)
          entities = entity.definition.entities
          faces = entities.grep(Sketchup::Face).select(&:valid?)
          edges = entities.grep(Sketchup::Edge).select(&:valid?)
          vertices = edges.flat_map(&:vertices).uniq
          vertex_indices = vertices.each_with_index.to_h
          face_indices = faces.each_with_index.to_h

          vertex_records = vertices.map.with_index do |vertex, index|
            point = vertex.position
            key = grid_key(point)
            snapped = snapped_components_inch(key)
            {
              index: index,
              source_vertex: vertex,
              source_position: point_components_inch(point),
              grid_key: key,
              snapped_position: snapped,
              displacement_mm: distance_components_mm(
                point_components_inch(point),
                snapped
              ),
              incident_edges: vertex.edges.length,
              incident_faces: vertex.faces.length
            }
          end

          collapse_classes = vertex_records.group_by { |record| record[:grid_key] }
                                           .select { |_key, records| records.length > 1 }
          snapped_unique_vertex_count =
            vertex_records.map { |record| record[:grid_key] }.uniq.length

          face_results = faces.map do |face|
            analyze_face(face, face_indices.fetch(face), vertex_indices, vertex_records)
          end

          candidate_edge_table = build_candidate_edge_table(face_results)
          global_reasons, global_metrics = analyze_global_topology(
            faces,
            face_indices,
            candidate_edge_table
          )

          face_reason_counts = Hash.new(0)
          face_results.each do |face_result|
            face_result[:reasons].each { |reason| face_reason_counts[reason] += 1 }
          end
          unsafe_face_count = face_results.count { |result| !result[:reasons].empty? }
          source_manifold = entity.respond_to?(:manifold?) ? entity.manifold? : nil
          global_reasons << :source_not_manifold unless source_manifold == true
          global_reasons.uniq!

          {
            label: entity_label(entity),
            pid: persistent_id(entity),
            status: :success,
            source: {
              faces: faces.length,
              edges: edges.length,
              vertices: vertices.length,
              manifold: source_manifold,
              component_count: source_face_component_count(faces, face_indices)
            },
            snap: {
              source_vertex_count: vertices.length,
              snapped_unique_vertex_count: snapped_unique_vertex_count,
              collapsed_vertex_delta: vertices.length - snapped_unique_vertex_count,
              collapse_class_count: collapse_classes.length,
              collapsed_source_vertex_count: collapse_classes.values.sum(&:length),
              max_displacement_mm:
                vertex_records.map { |record| record[:displacement_mm] }.max || 0.0,
              collapse_class_samples: collapse_classes.first(8).map do |key, records|
                {
                  grid_key: key,
                  source_vertex_indices: records.map { |record| record[:index] }
                }
              end
            },
            faces: {
              total: face_results.length,
              directly_preservable: face_results.count { |result| result[:reasons].empty? },
              unsafe: unsafe_face_count,
              reason_counts: face_reason_counts,
              unsafe_samples: face_results.reject { |result| result[:reasons].empty? }
                                          .first(MAX_UNSAFE_FACE_SAMPLES)
            },
            global: global_metrics.merge(reasons: global_reasons),
            directly_preservable:
              unsafe_face_count.zero? && global_reasons.empty?
          }
        end

        def analyze_face(face, face_index, vertex_indices, vertex_records)
          source_normal = [face.normal.x.to_f, face.normal.y.to_f, face.normal.z.to_f]
          loops = ordered_face_loops(face).map do |loop|
            source_indices = loop.vertices.map { |vertex| vertex_indices.fetch(vertex) }
            snapped_keys = source_indices.map do |vertex_index|
              vertex_records.fetch(vertex_index)[:grid_key]
            end
            cleaned_keys, removed_consecutive = remove_consecutive_duplicates(snapped_keys)
            {
              outer: loop == face.outer_loop,
              source_vertex_indices: source_indices,
              snapped_keys: cleaned_keys,
              removed_consecutive_duplicates: removed_consecutive
            }
          end

          reasons = []
          loops.each do |loop_record|
            keys = loop_record[:snapped_keys]
            reasons << :collapsed_below_3_vertices if keys.uniq.length < 3
            reasons << :repeated_vertex if keys.uniq.length != keys.length
          end

          all_keys = loops.flat_map { |loop_record| loop_record[:snapped_keys] }.uniq
          planarity = planarity_metrics(all_keys)
          reasons << :zero_area if planarity[:degenerate]
          reasons << :non_planar if
            !planarity[:degenerate] &&
            planarity[:max_deviation_mm] > PLANARITY_TOLERANCE_MM

          outer = loops.find { |loop_record| loop_record[:outer] }
          reasons << :missing_outer_loop unless outer

          projection_axis = dominant_axis(
            planarity[:normal] || source_normal
          )
          loops.each do |loop_record|
            projected = project_grid_loop(loop_record[:snapped_keys], projection_axis)
            loop_record[:projected] = projected
            reasons << :self_intersection if polygon_self_intersects?(projected)
            reasons << :zero_area if signed_area_twice(projected).zero?
          end

          if outer
            outer_normal = newell_normal_grid(outer[:snapped_keys])
            if vector_length(outer_normal).zero?
              reasons << :zero_area
            elsif vector_dot(outer_normal, source_normal).negative?
              reasons << :orientation_reversed
            end

            inner_loops = loops.reject { |loop_record| loop_record[:outer] }
            inner_loops.each do |inner|
              if polygons_intersect?(outer[:projected], inner[:projected])
                reasons << :outer_inner_intersection
              elsif !point_in_polygon_strict?(inner[:projected].first, outer[:projected])
                reasons << :hole_containment_changed
              end
            end
            inner_loops.combination(2) do |first, second|
              if polygons_intersect?(first[:projected], second[:projected]) ||
                 point_in_polygon_strict?(first[:projected].first, second[:projected]) ||
                 point_in_polygon_strict?(second[:projected].first, first[:projected])
                reasons << :inner_loop_intersection
              end
            end
          end

          {
            face_index: face_index,
            face_pid: persistent_id(face),
            outer_vertex_count: outer&.dig(:snapped_keys)&.length.to_i,
            inner_loop_count: loops.count { |loop_record| !loop_record[:outer] },
            removed_consecutive_duplicates:
              loops.sum { |loop_record| loop_record[:removed_consecutive_duplicates] },
            max_planarity_deviation_mm: planarity[:max_deviation_mm],
            loops: loops,
            reasons: reasons.uniq
          }
        end

        def ordered_face_loops(face)
          outer = face.outer_loop
          [outer] + face.loops.reject { |loop| loop == outer }
        end

        def remove_consecutive_duplicates(keys)
          cleaned = []
          removed = 0
          keys.each do |key|
            if cleaned.empty? || cleaned.last != key
              cleaned << key
            else
              removed += 1
            end
          end
          if cleaned.length > 1 && cleaned.first == cleaned.last
            cleaned.pop
            removed += 1
          end
          [cleaned, removed]
        end

        def build_candidate_edge_table(face_results)
          table = Hash.new { |hash, key| hash[key] = [] }
          face_results.each do |face_result|
            face_result[:loops].each do |loop_record|
              keys = loop_record[:snapped_keys]
              keys.each_index do |index|
                first = keys[index]
                second = keys[(index + 1) % keys.length]
                next if first == second

                undirected = canonical_edge(first, second)
                table[undirected] << {
                  face_index: face_result[:face_index],
                  direction: [first, second]
                }
              end
            end
          end
          table
        end

        def analyze_global_topology(faces, face_indices, edge_table)
          boundary = edge_table.count { |_edge, owners| owners.length == 1 }
          overused = edge_table.count { |_edge, owners| owners.length > 2 }
          direction_inconsistent = edge_table.count do |_edge, owners|
            next false unless owners.length == 2

            owners[0][:direction] == owners[1][:direction]
          end
          candidate_components = candidate_face_component_count(faces.length, edge_table)
          source_components = source_face_component_count(faces, face_indices)

          reasons = []
          reasons << :global_boundary_edge if boundary.positive?
          reasons << :global_overused_edge if overused.positive?
          reasons << :global_edge_direction_inconsistent if direction_inconsistent.positive?
          reasons << :global_component_count_changed if candidate_components != source_components

          [
            reasons,
            {
              candidate_edge_count: edge_table.length,
              boundary_edge_count: boundary,
              overused_edge_count: overused,
              direction_inconsistent_edge_count: direction_inconsistent,
              source_component_count: source_components,
              candidate_component_count: candidate_components
            }
          ]
        end

        def source_face_component_count(faces, face_indices)
          adjacency = Array.new(faces.length) { [] }
          faces.each do |face|
            first_index = face_indices.fetch(face)
            face.edges.each do |edge|
              edge.faces.each do |neighbor|
                next if neighbor == face
                second_index = face_indices[neighbor]
                next unless second_index

                adjacency[first_index] << second_index
              end
            end
          end
          component_count(adjacency)
        end

        def candidate_face_component_count(face_count, edge_table)
          adjacency = Array.new(face_count) { [] }
          edge_table.each_value do |owners|
            owners.map { |owner| owner[:face_index] }.uniq.combination(2) do |first, second|
              adjacency[first] << second
              adjacency[second] << first
            end
          end
          component_count(adjacency)
        end

        def component_count(adjacency)
          visited = Array.new(adjacency.length, false)
          count = 0
          adjacency.each_index do |seed|
            next if visited[seed]

            count += 1
            visited[seed] = true
            queue = [seed]
            until queue.empty?
              current = queue.shift
              adjacency[current].each do |neighbor|
                next if visited[neighbor]

                visited[neighbor] = true
                queue << neighbor
              end
            end
          end
          count
        end

        def planarity_metrics(grid_keys)
          points = grid_keys.map { |key| snapped_components_inch(key) }
          normal = nil
          origin = nil
          points.each_index do |first_index|
            ((first_index + 1)...points.length).each do |second_index|
              ((second_index + 1)...points.length).each do |third_index|
                candidate = vector_cross(
                  vector_subtract(points[second_index], points[first_index]),
                  vector_subtract(points[third_index], points[first_index])
                )
                next if vector_length(candidate).zero?

                normal = candidate
                origin = points[first_index]
                break
              end
              break if normal
            end
            break if normal
          end
          return { degenerate: true, normal: nil, max_deviation_mm: 0.0 } unless normal

          normal_length = vector_length(normal)
          max_deviation = points.map do |point|
            vector_dot(normal, vector_subtract(point, origin)).abs /
              normal_length * MM_PER_INCH
          end.max || 0.0
          {
            degenerate: false,
            normal: normal,
            max_deviation_mm: max_deviation
          }
        end

        def grid_key(point)
          [point.x, point.y, point.z].map do |coordinate|
            ((coordinate.to_f * MM_PER_INCH) / DEFAULT_TOLERANCE_MM).round
          end
        end

        def snapped_components_inch(key)
          key.map { |index| index * DEFAULT_TOLERANCE_MM / MM_PER_INCH }
        end

        def point_components_inch(point)
          [point.x.to_f, point.y.to_f, point.z.to_f]
        end

        def distance_components_mm(first, second)
          Math.sqrt(
            first.each_index.sum { |index| (first[index] - second[index])**2 }
          ) * MM_PER_INCH
        end

        def project_grid_loop(keys, drop_axis)
          keys.map do |key|
            key.each_with_index.filter_map do |value, index|
              value unless index == drop_axis
            end
          end
        end

        def dominant_axis(normal)
          normal.each_index.max_by { |index| normal[index].abs } || 2
        end

        def newell_normal_grid(keys)
          normal = [0.0, 0.0, 0.0]
          keys.each_index do |index|
            current = keys[index]
            following = keys[(index + 1) % keys.length]
            normal[0] += (current[1] - following[1]) * (current[2] + following[2])
            normal[1] += (current[2] - following[2]) * (current[0] + following[0])
            normal[2] += (current[0] - following[0]) * (current[1] + following[1])
          end
          normal
        end

        def polygon_self_intersects?(polygon)
          return true if polygon.length < 3

          edges = polygon.each_index.map do |index|
            [polygon[index], polygon[(index + 1) % polygon.length]]
          end
          edges.each_index do |first_index|
            ((first_index + 1)...edges.length).each do |second_index|
              next if adjacent_edge_indices?(first_index, second_index, edges.length)

              return true if segments_intersect_2d?(
                edges[first_index][0],
                edges[first_index][1],
                edges[second_index][0],
                edges[second_index][1]
              )
            end
          end
          false
        end

        def polygons_intersect?(first, second)
          return false if first.empty? || second.empty?

          first.each_index.any? do |first_index|
            first_start = first[first_index]
            first_end = first[(first_index + 1) % first.length]
            second.each_index.any? do |second_index|
              second_start = second[second_index]
              second_end = second[(second_index + 1) % second.length]
              segments_intersect_2d?(
                first_start,
                first_end,
                second_start,
                second_end
              )
            end
          end
        end

        def adjacent_edge_indices?(first, second, edge_count)
          return true if first == second
          return true if (first - second).abs == 1

          [first, second].min.zero? && [first, second].max == edge_count - 1
        end

        def segments_intersect_2d?(a, b, c, d)
          ab_c = orient_2d(a, b, c)
          ab_d = orient_2d(a, b, d)
          cd_a = orient_2d(c, d, a)
          cd_b = orient_2d(c, d, b)

          return true if ab_c.zero? && point_on_segment_2d?(c, a, b)
          return true if ab_d.zero? && point_on_segment_2d?(d, a, b)
          return true if cd_a.zero? && point_on_segment_2d?(a, c, d)
          return true if cd_b.zero? && point_on_segment_2d?(b, c, d)

          ((ab_c.positive? && ab_d.negative?) ||
            (ab_c.negative? && ab_d.positive?)) &&
            ((cd_a.positive? && cd_b.negative?) ||
              (cd_a.negative? && cd_b.positive?))
        end

        def orient_2d(a, b, c)
          ((b[0] - a[0]) * (c[1] - a[1])) -
            ((b[1] - a[1]) * (c[0] - a[0]))
        end

        def point_on_segment_2d?(point, start_point, end_point)
          orient_2d(start_point, end_point, point).zero? &&
            point[0] >= [start_point[0], end_point[0]].min &&
            point[0] <= [start_point[0], end_point[0]].max &&
            point[1] >= [start_point[1], end_point[1]].min &&
            point[1] <= [start_point[1], end_point[1]].max
        end

        def point_in_polygon_strict?(point, polygon)
          return false unless point
          return false if polygon.each_index.any? do |index|
            point_on_segment_2d?(
              point,
              polygon[index],
              polygon[(index + 1) % polygon.length]
            )
          end

          winding = 0
          polygon.each_index do |index|
            first = polygon[index]
            second = polygon[(index + 1) % polygon.length]
            if first[1] <= point[1]
              winding += 1 if second[1] > point[1] && orient_2d(first, second, point).positive?
            elsif second[1] <= point[1] && orient_2d(first, second, point).negative?
              winding -= 1
            end
          end
          !winding.zero?
        end

        def signed_area_twice(polygon)
          polygon.each_index.sum do |index|
            current = polygon[index]
            following = polygon[(index + 1) % polygon.length]
            (current[0] * following[1]) - (current[1] * following[0])
          end
        end

        def canonical_edge(first, second)
          (first <=> second) <= 0 ? [first, second] : [second, first]
        end

        def vector_subtract(first, second)
          [
            first[0] - second[0],
            first[1] - second[1],
            first[2] - second[2]
          ]
        end

        def vector_dot(first, second)
          (first[0] * second[0]) +
            (first[1] * second[1]) +
            (first[2] * second[2])
        end

        def vector_cross(first, second)
          [
            (first[1] * second[2]) - (first[2] * second[1]),
            (first[2] * second[0]) - (first[0] * second[2]),
            (first[0] * second[1]) - (first[1] * second[0])
          ]
        end

        def vector_length(vector)
          Math.sqrt(vector_dot(vector, vector))
        end

        def persistent_id(entity)
          entity.persistent_id if entity.respond_to?(:persistent_id)
        rescue StandardError
          nil
        end

        def entity_label(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          label = name.empty? ? entity.class.to_s : name
          pid = persistent_id(entity)
          pid ? "#{label}[PID=#{pid}]" : label
        rescue StandardError
          entity.class.to_s
        end

        def print_entity_result(result)
          source = result[:source]
          snap = result[:snap]
          face_data = result[:faces]
          global = result[:global]
          puts format(
            'source                : F=%d E=%d V=%d manifold=%s components=%d',
            source[:faces],
            source[:edges],
            source[:vertices],
            source[:manifold].inspect,
            source[:component_count]
          )
          puts format(
            'grid snap             : uniqueV=%d collapsed_delta=%d classes=%d members=%d max_move=%.9f mm',
            snap[:snapped_unique_vertex_count],
            snap[:collapsed_vertex_delta],
            snap[:collapse_class_count],
            snap[:collapsed_source_vertex_count],
            snap[:max_displacement_mm]
          )
          puts format(
            'Face feasibility      : direct=%d unsafe=%d total=%d',
            face_data[:directly_preservable],
            face_data[:unsafe],
            face_data[:total]
          )
          if face_data[:reason_counts].empty?
            puts 'Face unsafe reasons   : none'
          else
            puts 'Face unsafe reasons:'
            face_data[:reason_counts].sort_by { |reason, count| [-count, reason.to_s] }
                                     .each do |reason, count|
              puts format('  %-38s %6d', reason, count)
            end
          end
          puts format(
            'global topology       : edges=%d boundary=%d overused=%d direction_conflicts=%d components=%d→%d',
            global[:candidate_edge_count],
            global[:boundary_edge_count],
            global[:overused_edge_count],
            global[:direction_inconsistent_edge_count],
            global[:source_component_count],
            global[:candidate_component_count]
          )
          puts format(
            'global unsafe reasons : %s',
            global[:reasons].empty? ? 'none' : global[:reasons].join(', ')
          )
          puts format(
            'polygon V1 candidate  : %s',
            result[:directly_preservable] ? 'ACCEPTABLE FOR COPY RECONSTRUCTION PROBE' : 'REJECT / EXISTING LVN FALLBACK'
          )

          face_data[:unsafe_samples].each do |sample|
            puts format(
              '  unsafe Face[%d] PID=%s reasons=%s d2p=%.9f mm outerV=%d holes=%d',
              sample[:face_index],
              sample[:face_pid].inspect,
              sample[:reasons].join(','),
              sample[:max_planarity_deviation_mm],
              sample[:outer_vertex_count],
              sample[:inner_loop_count]
            )
          end
        end

        def print_summary(results)
          puts '=' * 92
          puts ' Phase 1 Feasibility Summary'
          puts '=' * 92
          successes = results.select { |result| result[:status] == :success }
          errors = results.select { |result| result[:status] == :error }
          accepted = successes.count { |result| result[:directly_preservable] }
          rejected = successes.length - accepted
          reason_counts = Hash.new(0)
          successes.each do |result|
            result[:faces][:reason_counts].each do |reason, count|
              reason_counts[reason] += count
            end
            result[:global][:reasons].each { |reason| reason_counts[reason] += 1 }
          end

          puts format('analyzed solids       : %d', successes.length)
          puts format('polygon candidates    : %d', accepted)
          puts format('existing LVN fallback : %d', rejected)
          puts format('probe errors          : %d', errors.length)
          if successes.any?
            rate = accepted.to_f / successes.length * 100.0
            puts format('candidate rate        : %.2f%%', rate)
          end
          unless reason_counts.empty?
            puts 'aggregate reject reasons:'
            reason_counts.sort_by { |reason, count| [-count, reason.to_s] }
                         .each do |reason, count|
              puts format('  %-38s %8d', reason, count)
            end
          end
          puts 'geometry mutations    : 0'
          puts format('result                : %s', errors.empty? ? 'PASS' : 'ERROR')
          puts '=' * 92
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::
  LvnPolygonPreservingFeasibilityProbe.run(mode: :first)

nil
