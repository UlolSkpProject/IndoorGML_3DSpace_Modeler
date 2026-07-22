# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # X/Y/Z constrain independent coordinates and therefore coexist. The
        # priority controls deterministic processing/report order only. Competing
        # targets are resolved within the same axis by source displacement and
        # source-plane spread; an exact unresolved tie aborts normalization.
        def axis_plane_normalization_plan(entities)
          records = entities.grep(@face_class).filter_map do |face|
            axis_plane_face_record(face)
          end
          clusters = []
          axis_components = []
          candidates_by_point = Hash.new do |point_hash, point_key|
            point_hash[point_key] = Hash.new { |axis_hash, axis| axis_hash[axis] = [] }
          end

          records.group_by { |record| record[:axis] }.each do |axis, axis_records|
            axis_plane_connected_components(axis_records).each do |component|
              component_vertices = component.flat_map { |record| record[:vertices] }
                                            .uniq { |vertex| stable_entity_id(vertex) }
              coordinates = component_vertices.map do |vertex|
                point_coordinate(vertex.position, axis) * MM_PER_INCH
              end
              spread = coordinates.max.to_f - coordinates.min.to_f
              target_index = (median_value(coordinates) / @tolerance_mm).round
              target_mm = target_index * @tolerance_mm
              axis_components << {
                axis: axis,
                target_index: target_index,
                records: component
              }
              displacements = coordinates.map { |coordinate| (coordinate - target_mm).abs }

              cluster = {
                axis: axis,
                target_index: target_index,
                target_mm: target_mm,
                face_count: component.length,
                vertex_count: component_vertices.length,
                source_spread_mm: spread,
                max_displacement_mm: displacements.max || 0.0,
                face_keys: component.map { |record| stable_entity_id(record[:face]) }
              }
              clusters << cluster

              component_vertices.each do |vertex|
                point_key = source_point_key(vertex.position)
                source_coordinate_mm = point_coordinate(vertex.position, axis) * MM_PER_INCH
                candidates_by_point[point_key][axis] << {
                  axis: axis,
                  target_index: target_index,
                  displacement_mm: (source_coordinate_mm - target_mm).abs,
                  source_spread_mm: spread,
                  cluster: cluster
                }
              end
            end
          end

          constraints = {}
          resolved_conflicts = []
          discarded_count = 0

          candidates_by_point.each do |point_key, candidates_by_axis|
            selected_axes = {}
            AXIS_CONSTRAINT_PRIORITY.each do |axis|
              candidates = candidates_by_axis[axis]
              next if candidates.empty?

              selected, discarded = select_axis_constraint_candidate!(
                point_key,
                axis,
                candidates
              )
              selected_axes[axis] = selected[:target_index]
              next if discarded.empty?

              discarded_count += discarded.length
              resolved_conflicts << {
                point: point_key,
                axis: axis,
                selected_target_index: selected[:target_index],
                selected_displacement_mm: selected[:displacement_mm],
                selected_source_spread_mm: selected[:source_spread_mm],
                discarded: discarded.map do |candidate|
                  {
                    target_index: candidate[:target_index],
                    displacement_mm: candidate[:displacement_mm],
                    source_spread_mm: candidate[:source_spread_mm]
                  }
                end
              }
            end
            constraints[point_key] = selected_axes unless selected_axes.empty?
          end

          topology_components = axis_components.group_by do |entry|
            [entry[:axis], entry[:target_index]]
          end.flat_map do |(axis, target_index), entries|
            axis_plane_geometric_components(
              entries.flat_map { |entry| entry[:records] }
            ).map do |component|
              {
                axis: axis,
                target_index: target_index,
                records: component
              }
            end
          end
          topology_repairs = repair_axis_plane_boundary_targets!(
            topology_components,
            constraints
          )

          max_displacement_mm = constraints.flat_map do |point_key, axes|
            axes.map do |axis, target_index|
              ((point_key[axis] * MM_PER_INCH) - (target_index * @tolerance_mm)).abs
            end
          end.max || 0.0

          {
            constraints: constraints,
            clusters: clusters,
            face_count: clusters.sum { |cluster| cluster[:face_count] },
            cluster_count: clusters.length,
            constrained_vertex_count: constraints.length,
            constrained_coordinate_count: constraints.values.sum(&:length),
            multi_axis_constrained_vertex_count:
              constraints.values.count { |axes| axes.length > 1 },
            max_displacement_mm: max_displacement_mm,
            axis_cluster_counts: clusters.group_by { |cluster| cluster[:axis] }
                                         .transform_values(&:length),
            axis_priority: AXIS_CONSTRAINT_PRIORITY.dup,
            resolved_constraint_conflicts: resolved_conflicts,
            resolved_constraint_conflict_count: resolved_conflicts.length,
            discarded_constraint_count: discarded_count,
            topology_preserving_target_repairs: topology_repairs,
            topology_preserving_target_repair_count: topology_repairs.length
          }
        end

        # Independent nearest-grid rounding is not topology preserving: two
        # non-intersecting source boundary segments can cross after each endpoint
        # is rounded separately. For each connected axis-plane component, retain
        # its source boundary graph and choose the nearest floor/ceil grid targets
        # that keep every exterior/hole loop simple with the same orientation.
        def repair_axis_plane_boundary_targets!(components, constraints)
          repairs = []
          components.each do |entry|
            boundary = axis_plane_component_source_boundary(
              entry[:records],
              entry[:axis]
            )
            next unless boundary

            20.times do
              mapped = mapped_source_boundary_loops(boundary, constraints)
              break if mapped_boundary_topology_valid?(boundary[:loops], mapped, entry[:axis])

              crossing = first_mapped_boundary_crossing(mapped, entry[:axis])
              break unless crossing

              solution = topology_preserving_boundary_target_solution(
                boundary,
                mapped,
                crossing,
                constraints,
                entry[:axis]
              )
              break unless solution

              solution[:targets].each do |source_key, target|
                point = boundary[:point_by_key].fetch(source_key)
                point_key = source_point_key(point)
                constraints[point_key] ||= {}
                3.times do |axis|
                  current = normalized_target(
                    point,
                    { constraints: constraints }
                  )
                  current_key = grid_indices(current)
                  constraints[point_key][axis] = target[axis] if
                    current_key[axis] != target[axis]
                end
              end
              repairs << {
                axis: entry[:axis],
                face_keys: entry[:records].map do |record|
                  stable_entity_id(record[:face])
                end,
                changed_source_points: solution[:targets].keys,
                max_displacement_mm: solution[:max_displacement_mm]
              }
            end
          end
          repairs
        end

        # SketchUp edge identity is insufficient for topology constraints: one
        # Face may own a long edge while its neighbour owns several collinear
        # sub-edges. Build connected components from the split source segments.
        def axis_plane_geometric_components(records)
          return [] if records.empty?

          point_keys = records.flat_map do |record|
            record[:face].loops.flat_map do |loop|
              loop.vertices.map do |vertex|
                source_precision_indices(vertex.position)
              end
            end
          end.uniq
          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, record_index|
            record[:face].loops.each do |loop|
              points = compact_integer_loop(loop.vertices.map do |vertex|
                source_precision_indices(vertex.position)
              end)
              points.each_index do |index|
                point_a = points[index]
                point_b = points[(index + 1) % points.length]
                integer_points_on_segment_sorted(point_a, point_b, point_keys)
                  .each_cons(2) do |segment_start, segment_end|
                    next if segment_start == segment_end

                    edge = canonical_edge_key(segment_start, segment_end)
                    edge_owners[edge] << record_index unless
                      edge_owners[edge].include?(record_index)
                  end
              end
            end
          end

          adjacency = Array.new(records.length) { [] }
          edge_owners.each_value do |owners|
            owners.combination(2) do |first, second|
              adjacency[first] << second
              adjacency[second] << first
            end
          end
          visited = Array.new(records.length, false)
          records.each_index.filter_map do |seed|
            next if visited[seed]

            visited[seed] = true
            queue = [seed]
            component = []
            until queue.empty?
              index = queue.shift
              component << records[index]
              adjacency[index].each do |neighbor|
                next if visited[neighbor]

                visited[neighbor] = true
                queue << neighbor
              end
            end
            component
          end
        rescue StandardError
          records.map { |record| [record] }
        end

        def axis_plane_component_source_boundary(records, drop_axis)
          faces = records.map { |record| record[:face] }
          return nil if faces.empty? || faces.any? { |face| !face.respond_to?(:loops) }

          point_by_key = {}
          face_loops = faces.flat_map do |face|
            face.loops.map do |loop|
              compact_integer_loop(loop.vertices.map do |vertex|
                point = vertex.position
                key = source_precision_indices(point)
                point_by_key[key] ||= point
                key
              end)
            end
          end
          return nil if face_loops.empty? || face_loops.any? { |loop| loop.length < 3 }

          all_points = face_loops.flatten(1).uniq
          incidence = Hash.new(0)
          face_loops.each do |loop|
            loop.each_index do |index|
              point_a = loop[index]
              point_b = loop[(index + 1) % loop.length]
              integer_points_on_segment_sorted(point_a, point_b, all_points)
                .each_cons(2) do |segment_start, segment_end|
                  next if segment_start == segment_end

                  incidence[canonical_edge_key(segment_start, segment_end)] += 1
                end
            end
          end
          return nil if incidence.values.any? { |count| count > 2 }

          boundary_edges = incidence.filter_map do |edge, count|
            edge if count == 1
          end
          loops = exact_boundary_loops(boundary_edges)
          projected = loops.map do |loop|
            loop.map { |point| integer_project_2d(point, drop_axis) }
          end
          return nil unless projected.all? do |polygon|
            !integer_polygon_area2(polygon).zero? &&
              simple_integer_polygon_2d?(polygon)
          end

          {
            loops: loops,
            point_by_key: point_by_key
          }
        rescue Error, ArgumentError
          nil
        end

        def mapped_source_boundary_loops(boundary, constraints)
          plan = { constraints: constraints }
          boundary[:loops].map do |loop|
            loop.map do |source_key|
              point = boundary[:point_by_key].fetch(source_key)
              grid_indices(normalized_target(point, plan))
            end
          end
        end

        def mapped_boundary_topology_valid?(source_loops, mapped_loops, drop_axis)
          return false unless source_loops.length == mapped_loops.length
          return false if mapped_loops.any? do |loop|
            loop.uniq.length != loop.length || loop.length < 3
          end

          source_loops.zip(mapped_loops).all? do |source_loop, mapped_loop|
            source_polygon = source_loop.map do |point|
              integer_project_2d(point, drop_axis)
            end
            mapped_polygon = mapped_loop.map do |point|
              integer_project_2d(point, drop_axis)
            end
            source_sign = integer_polygon_area2(source_polygon) <=> 0
            mapped_sign = integer_polygon_area2(mapped_polygon) <=> 0
            source_sign == mapped_sign &&
              simple_integer_polygon_2d?(mapped_polygon)
          end && mapped_boundary_loops_disjoint?(mapped_loops, drop_axis)
        end

        def mapped_boundary_loops_disjoint?(loops, drop_axis)
          projected = loops.map do |loop|
            loop.map { |point| integer_project_2d(point, drop_axis) }
          end
          projected.each_index do |first_loop_index|
            ((first_loop_index + 1)...projected.length).each do |second_loop_index|
              first = projected[first_loop_index]
              second = projected[second_loop_index]
              first.each_index do |first_edge_index|
                second.each_index do |second_edge_index|
                  return false if integer_segments_intersect_2d?(
                    first[first_edge_index],
                    first[(first_edge_index + 1) % first.length],
                    second[second_edge_index],
                    second[(second_edge_index + 1) % second.length]
                  )
                end
              end
            end
          end
          true
        end

        def first_mapped_boundary_crossing(mapped_loops, drop_axis)
          mapped_loops.each_with_index do |loop, loop_index|
            polygon = loop.map { |point| integer_project_2d(point, drop_axis) }
            polygon.length.times do |first_index|
              point_a = polygon[first_index]
              point_b = polygon[(first_index + 1) % polygon.length]
              ((first_index + 1)...polygon.length).each do |second_index|
                next if second_index == (first_index + 1) % polygon.length
                next if (second_index + 1) % polygon.length == first_index

                point_c = polygon[second_index]
                point_d = polygon[(second_index + 1) % polygon.length]
                next unless integer_segments_intersect_2d?(
                  point_a, point_b, point_c, point_d
                )

                return {
                  loop_indices: [loop_index, loop_index],
                  vertex_indices: [first_index, (first_index + 1) % polygon.length,
                                   second_index, (second_index + 1) % polygon.length]
                }
              end
            end
          end


          projected = mapped_loops.map do |loop|
            loop.map { |point| integer_project_2d(point, drop_axis) }
          end
          projected.each_index do |first_loop_index|
            ((first_loop_index + 1)...projected.length).each do |second_loop_index|
              first = projected[first_loop_index]
              second = projected[second_loop_index]
              first.each_index do |first_index|
                second.each_index do |second_index|
                  next unless integer_segments_intersect_2d?(
                    first[first_index], first[(first_index + 1) % first.length],
                    second[second_index], second[(second_index + 1) % second.length]
                  )

                  return {
                    loop_indices: [first_loop_index, second_loop_index],
                    vertex_indices: [first_index, (first_index + 1) % first.length,
                                     second_index, (second_index + 1) % second.length]
                  }
                end
              end
            end
          end
          nil
        end

        def topology_preserving_boundary_target_solution(
          boundary,
          mapped_loops,
          crossing,
          constraints,
          drop_axis
        )
          source_keys = crossing[:loop_indices].zip(
            crossing[:vertex_indices].each_slice(2).to_a
          ).flat_map do |loop_index, indices|
            source_loop = boundary[:loops].fetch(loop_index)
            indices.map { |index| source_loop.fetch(index) }
          end.uniq
          candidate_sets = source_keys.map do |source_key|
            point = boundary[:point_by_key].fetch(source_key)
            point_key = source_point_key(point)
            fixed = constraints[point_key] || {}
            3.times.map do |axis|
              if fixed.key?(axis)
                [fixed[axis]]
              else
                coordinate = point_coordinate(point, axis) * MM_PER_INCH
                scaled = coordinate / @tolerance_mm
                [scaled.floor, scaled.ceil].uniq
              end
            end.then do |axes|
              axes[0].product(axes[1], axes[2])
            end
          end

          best = nil
          candidate_sets.first.product(*candidate_sets.drop(1)).each do |targets|
            replacements = source_keys.zip(targets).to_h
            candidate_loops = boundary[:loops].map do |loop|
              loop.map do |source_key|
                replacements[source_key] || begin
                  point = boundary[:point_by_key].fetch(source_key)
                  grid_indices(normalized_target(point, { constraints: constraints }))
                end
              end
            end
            next unless mapped_boundary_topology_valid?(
              boundary[:loops],
              candidate_loops,
              drop_axis
            )

            displacement_squared = replacements.sum do |source_key, target|
              point = boundary[:point_by_key].fetch(source_key)
              3.times.sum do |axis|
                source_mm = point_coordinate(point, axis) * MM_PER_INCH
                delta = (target[axis] * @tolerance_mm) - source_mm
                delta * delta
              end
            end
            candidate = {
              targets: replacements,
              displacement_squared: displacement_squared,
              max_displacement_mm: replacements.map do |source_key, target|
                point = boundary[:point_by_key].fetch(source_key)
                Math.sqrt(3.times.sum do |axis|
                  source_mm = point_coordinate(point, axis) * MM_PER_INCH
                  delta = (target[axis] * @tolerance_mm) - source_mm
                  delta * delta
                end)
              end.max || 0.0
            }
            best = candidate if best.nil? ||
              candidate[:displacement_squared] < best[:displacement_squared]
          end
          best
        end

        def select_axis_constraint_candidate!(point_key, axis, candidates)
          ranked = candidates.sort_by do |candidate|
            [
              candidate[:displacement_mm],
              candidate[:source_spread_mm],
              candidate[:target_index]
            ]
          end
          selected = ranked.first
          equally_ranked = ranked.select do |candidate|
            (candidate[:displacement_mm] - selected[:displacement_mm]).abs <= GRID_EPSILON_MM &&
              (candidate[:source_spread_mm] - selected[:source_spread_mm]).abs <= GRID_EPSILON_MM
          end
          tied_targets = equally_ranked.map { |candidate| candidate[:target_index] }.uniq
          if tied_targets.length > 1
            raise ReconstructionError,
                  "Ambiguous same-axis plane constraints at #{point_key.inspect}: " \
                  "axis=#{axis} targets=#{tied_targets.inspect}"
          end

          discarded = ranked.reject { |candidate| candidate.equal?(selected) }
          [selected, discarded]
        end

        def normalized_vertex_metrics(vertices, axis_plane_plan = nil)
          targets = Hash.new { |hash, key| hash[key] = [] }
          moved_count = 0
          max_displacement_mm = 0.0

          vertices.each do |vertex|
            target = normalized_target(vertex.position, axis_plane_plan)
            target_key = grid_indices(target)
            targets[target_key] << source_point_key(vertex.position)
            displacement_mm = point_distance_mm(vertex.position, target)
            moved_count += 1 if displacement_mm > GRID_EPSILON_MM
            max_displacement_mm = displacement_mm if displacement_mm > max_displacement_mm
          end

          collisions = targets.filter_map do |target, sources|
            unique_sources = sources.uniq
            next if unique_sources.length < 2

            { target: target, source_points: unique_sources }
          end

          {
            unique_target_count: targets.length,
            moved_count: moved_count,
            max_displacement_mm: max_displacement_mm,
            target_collision_count: collisions.length,
            merged_target_vertex_count: collisions.sum { |entry| entry[:source_points].length - 1 },
            target_collisions: collisions.first(100)
          }
        end

        # Target collisions are allowed, but every collapsed or newly duplicated
        # triangle marks its source face and adjacent source faces for forced
        # coplanar-patch reconstruction before the hard mesh-validation gate.
        def normalize_triangle_records_allowing_collisions(
          triangle_records,
          axis_plane_plan = nil,
          duplicate_diagnostics: nil
        )
          normalized_records = triangle_records.map do |source_record|
            source_record.merge(
              points: source_record[:points].map do |point|
                normalized_target(point, axis_plane_plan)
              end
            )
          end

          collapsed_indices = normalized_records.each_index.select do |index|
            normalized_records[index][:points]
              .map { |point| grid_indices(point) }
              .uniq.length != 3
          end
          duplicate_indices = collision_duplicate_triangle_indices(
            triangle_records,
            normalized_records
          )
          affected_indices = (collapsed_indices + duplicate_indices).uniq
          failure_set = empty_repair_failure_set
          add_repair_failure!(
            failure_set,
            reason: :collapsed_triangle,
            triangle_indices: collapsed_indices,
            source_face_keys: collapsed_indices.map do |index|
              triangle_records[index][:source_face_key]
            end
          ) unless collapsed_indices.empty?
          add_repair_failure!(
            failure_set,
            reason: :collision_duplicate_triangle,
            triangle_indices: duplicate_indices,
            source_face_keys: duplicate_indices.map do |index|
              triangle_records[index][:source_face_key]
            end
          ) unless duplicate_indices.empty?
          if affected_indices.empty?
            if duplicate_diagnostics
              duplicate_diagnostics[:duplicate_count] ||= 0
              duplicate_diagnostics[:samples] ||= []
            end
            return [
              normalized_records,
              {
                removed_coincident_triangle_count: 0,
                removed_collinear_triangle_count: 0,
                removed_duplicate_triangle_count: 0,
                affected_source_face_keys: [],
                forced_source_face_keys: [],
                collapsed_triangle_count: 0,
                collision_duplicate_triangle_count: 0,
                repair_failure_set:
                  finalize_repair_failure_set(failure_set)
              }
            ]
          end

          forced_face_keys = source_face_keys_with_adjacent_triangles(
            triangle_records,
            affected_indices,
            coordinate_space: :source
          )

          sanitized, cleanup = sanitize_triangle_records(
            normalized_records,
            duplicate_diagnostics: duplicate_diagnostics,
            remove_collinear: false
          )
          cleanup[:forced_source_face_keys] = forced_face_keys
          cleanup[:collapsed_triangle_count] = collapsed_indices.length
          cleanup[:collision_duplicate_triangle_count] = duplicate_indices.length
          cleanup[:repair_failure_set] = finalize_repair_failure_set(failure_set)
          [sanitized, cleanup]
        end

        def collision_duplicate_triangle_indices(source_records, normalized_records)
          normalized_groups = Hash.new { |hash, key| hash[key] = [] }
          normalized_records.each_with_index do |record, index|
            triangle = record[:points].map { |point| grid_indices(point) }
            next unless triangle.uniq.length == 3

            normalized_groups[canonical_triangle_key(triangle)] << index
          end

          normalized_groups.values.flat_map do |indices|
            next [] if indices.length < 2

            source_signatures = indices.map do |index|
              triangle_signature_for_space(source_records[index][:points], :source)
            end.uniq
            source_signatures.length > 1 ? indices : []
          end.uniq
        end

        def source_face_keys_with_adjacent_triangles(
          triangle_records,
          affected_indices,
          coordinate_space:
        )
          return [] if affected_indices.empty?

          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          triangle_records.each_with_index do |record, index|
            keys = record[:points].map do |point|
              triangle_point_key(point, coordinate_space)
            end
            3.times do |edge_index|
              edge = canonical_edge_key(
                keys[edge_index],
                keys[(edge_index + 1) % 3]
              )
              edge_owners[edge] << index
            end
          end

          expanded = affected_indices.dup
          affected_indices.each do |index|
            keys = triangle_records[index][:points].map do |point|
              triangle_point_key(point, coordinate_space)
            end
            3.times do |edge_index|
              edge = canonical_edge_key(
                keys[edge_index],
                keys[(edge_index + 1) % 3]
              )
              expanded.concat(edge_owners[edge])
            end
          end

          expanded.uniq.filter_map do |index|
            triangle_records[index][:source_face_key]
          end.uniq
        end

        # Creates a provenance-preserving worklist for localized repair stages.
        def empty_repair_failure_set
          {
            vertex_keys: [],
            edge_keys: [],
            triangle_indices: [],
            source_face_keys: [],
            patch_indices: [],
            reasons: {}
          }
        end

        # Adds one detected defect and its minimal known repair provenance.
        def add_repair_failure!(
          failure_set,
          reason:,
          vertex_keys: [],
          edge_keys: [],
          triangle_indices: [],
          source_face_keys: [],
          patch_indices: []
        )
          failure_set[:vertex_keys].concat(Array(vertex_keys))
          failure_set[:edge_keys].concat(Array(edge_keys))
          failure_set[:triangle_indices].concat(Array(triangle_indices))
          failure_set[:source_face_keys].concat(Array(source_face_keys).compact)
          failure_set[:patch_indices].concat(Array(patch_indices))
          failure_set[:reasons][reason] = failure_set[:reasons].fetch(reason, 0) + 1
          failure_set
        end

        # Freezes a repair worklist into unique deterministic arrays for reports.
        def finalize_repair_failure_set(failure_set)
          failure_set.each_with_object({}) do |(key, value), result|
            result[key] = if key == :reasons
                            value.dup
                          else
                            value.uniq.sort_by(&:inspect)
                          end
          end
        end

        def sanitize_triangle_records(
          triangle_records,
          duplicate_diagnostics: nil,
          remove_collinear: true
        )
          diagnostics = duplicate_diagnostics || {}
          diagnostics[:duplicate_count] ||= 0
          diagnostics[:samples] ||= []
          signatures = {}
          removed_coincident = 0
          removed_collinear = 0
          removed_duplicate = 0
          affected_source_face_keys = []

          records = triangle_records.filter_map do |record|
            triangle = record[:points].map { |point| grid_indices(point) }
            if triangle.uniq.length != 3
              removed_coincident += 1
              affected_source_face_keys << record[:source_face_key]
              next
            end
            if remove_collinear && integer_zero_vector?(integer_triangle_normal(triangle))
              removed_collinear += 1
              affected_source_face_keys << record[:source_face_key]
              next
            end

            signature = canonical_triangle_key(triangle)
            if signatures.key?(signature)
              removed_duplicate += 1
              affected_source_face_keys << record[:source_face_key]
              affected_source_face_keys << signatures[signature][:source_face_key]
              diagnostics[:duplicate_count] += 1
              if diagnostics[:samples].length < 10
                diagnostics[:samples] << {
                  signature: signature,
                  kept_face_key: signatures[signature][:source_face_key],
                  duplicate_face_key: record[:source_face_key]
                }
              end
              next
            end

            signatures[signature] = record
            record
          end

          [
            records,
            {
              removed_coincident_triangle_count: removed_coincident,
              removed_collinear_triangle_count: removed_collinear,
              removed_duplicate_triangle_count: removed_duplicate,
              affected_source_face_keys: affected_source_face_keys.compact.uniq
            }
          ]
        end

        def triangle_mesh_inventory(triangle_records)
          triangles = triangle_records.map do |record|
            record[:points].map { |point| grid_indices(point) }
          end
          vertices = {}
          edge_incidence = Hash.new { |hash, key| hash[key] = [] }
          adjacency = Array.new(triangles.length) { [] }

          triangles.each_with_index do |triangle, triangle_index|
            triangle.each { |vertex| vertices[vertex] = true }
            3.times do |edge_index|
              edge = canonical_edge_key(
                triangle[edge_index],
                triangle[(edge_index + 1) % 3]
              )
              edge_incidence[edge] << triangle_index
            end
          end
          edge_incidence.each_value do |owners|
            owners.combination(2) do |first, second|
              adjacency[first] << second
              adjacency[second] << first
            end
          end

          {
            vertex_count: vertices.length,
            edge_count: edge_incidence.length,
            triangle_count: triangles.length,
            component_count: triangles.empty? ? 0 : graph_component_count(adjacency),
            boundary_edge_count: edge_incidence.count { |_edge, owners| owners.length == 1 },
            overused_edge_count: edge_incidence.count { |_edge, owners| owners.length > 2 },
            closed_2_manifold: !triangles.empty? &&
              edge_incidence.values.all? { |owners| owners.length == 2 }
          }
        end

        def validate_sliver_topology_when_comparable!(before, after, report)
          report[:euler_characteristic_before] = triangle_mesh_euler_characteristic(before)
          report[:euler_characteristic_after] = triangle_mesh_euler_characteristic(after)
          return unless report[:repairable]
          return unless before[:closed_2_manifold]

          validate_short_edge_sliver_topology!(before, after, report)
        end

        def merge_triangle_cleanup_reports!(sliver_report, cleanup)
          sliver_report[:removed_degenerate_triangle_count] =
            sliver_report[:removed_degenerate_triangle_count].to_i +
            cleanup[:removed_coincident_triangle_count].to_i +
            cleanup[:removed_collinear_triangle_count].to_i
          sliver_report[:removed_duplicate_triangle_count] =
            sliver_report[:removed_duplicate_triangle_count].to_i +
            cleanup[:removed_duplicate_triangle_count].to_i
        end

        # Zero-area repair remains local. If the alternate diagonal is still a
        # sliver, or if local repair cannot be completed, the affected source-face
        # neighborhood is explicitly forced through step-6 patch reconstruction.
        def repair_grid_triangles_with_patch_fallback(triangle_records)
          degenerate_indices = triangle_records.each_index.select do |index|
            degenerate_triangle_record?(triangle_records[index])
          end
          if degenerate_indices.empty?
            return [
              triangle_records,
              {
                repaired_triangles: 0,
                replaced_pairs: 0,
                forced_source_face_keys: [],
                alternate_sliver_triangle_count: 0,
                deferred_to_patch_retriangulation: false,
                repair_failure_set:
                  finalize_repair_failure_set(empty_repair_failure_set)
              }
            ]
          end

          failure_set = empty_repair_failure_set
          add_repair_failure!(
            failure_set,
            reason: :degenerate_triangle,
            triangle_indices: degenerate_indices,
            source_face_keys: degenerate_indices.map do |index|
              triangle_records[index][:source_face_key]
            end
          )
          failure_set = finalize_repair_failure_set(failure_set)

          forced_face_keys = source_face_keys_with_adjacent_triangles(
            triangle_records,
            degenerate_indices,
            coordinate_space: :grid
          )
          original_valid_signatures = triangle_records.each_with_object({}) do |record, result|
            next if degenerate_triangle_record?(record)

            result[canonical_triangle_key(record[:points].map { |point| grid_indices(point) })] = true
          end

          repaired, report = repair_degenerate_source_triangles(triangle_records)
          replacement_records = repaired.reject do |record|
            signature = canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
            original_valid_signatures[signature]
          end
          alternate_slivers = replacement_records.select do |record|
            grid_triangle_sliver?(record[:points])
          end
          forced_face_keys.concat(
            alternate_slivers.filter_map { |record| record[:source_face_key] }
          )
          report = report.merge(
            forced_source_face_keys: forced_face_keys.uniq,
            alternate_sliver_triangle_count: alternate_slivers.length,
            deferred_to_patch_retriangulation: alternate_slivers.any?,
            repair_failure_set: report[:repair_failure_set] || failure_set
          )
          [repaired, report]
        rescue ReconstructionError => error
          sanitized, cleanup = sanitize_triangle_records(
            triangle_records,
            remove_collinear: true
          )
          forced_face_keys.concat(cleanup[:affected_source_face_keys]) if defined?(forced_face_keys)
          [
            sanitized,
            {
              repaired_triangles: 0,
              replaced_pairs: 0,
              deferred_to_patch_retriangulation: true,
              fallback_reason: "#{error.class}: #{error.message}",
              forced_source_face_keys: Array(forced_face_keys).compact.uniq,
              removed_coincident_triangles:
                cleanup[:removed_coincident_triangle_count],
              removed_collinear_triangles:
                cleanup[:removed_collinear_triangle_count],
              removed_duplicate_triangles:
                cleanup[:removed_duplicate_triangle_count],
              repair_failure_set: failure_set
            }
          ]
        end

        def grid_triangle_sliver?(points)
          triangle = points.map { |point| grid_indices(point) }
          return true if triangle.uniq.length != 3
          return true if integer_zero_vector?(integer_triangle_normal(triangle))

          altitude_mm = exact_triangle_minimum_altitude_mm(triangle)
          edge_lengths = 3.times.map do |index|
            edge = integer_subtract(triangle[index], triangle[(index + 1) % 3])
            Math.sqrt(integer_dot(edge, edge).to_f) * @tolerance_mm
          end
          longest = edge_lengths.max
          aspect_ratio = altitude_mm.positive? ? longest / altitude_mm : Float::INFINITY
          altitude_mm < @tolerance_mm ||
            (aspect_ratio >= SHORT_EDGE_SLIVER_MIN_ASPECT_RATIO &&
             edge_lengths.min < SHORT_EDGE_SLIVER_THRESHOLD_MM)
        end

      end
    end
  end
end
