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
            discarded_constraint_count: discarded_count
          }
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
            deferred_to_patch_retriangulation: alternate_slivers.any?
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
                cleanup[:removed_duplicate_triangle_count]
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

        # Step 6 accepts explicit forced source-face keys from collision, local
        # diagonal, and sliver processing. Unaffected healthy patches are retained.
        def retriangulate_exact_coplanar_patches(
          triangle_records,
          forced_source_face_keys: [],
          force_all: false
        )
          forced_keys = Array(forced_source_face_keys).compact.to_h { |key| [key, true] }
          patches = exact_coplanar_triangle_patches(triangle_records)
          rebuilt_records = []
          rebuilt_patches = 0
          preserved_patches = 0
          forced_patches = 0
          source_triangle_count = 0
          rebuilt_triangle_count = 0
          boundary_loop_count = 0
          hole_count = 0

          patches.each do |patch|
            forced = force_all || patch.any? do |record|
              forced_keys[record[:source_face_key]]
            end
            required = forced || exact_coplanar_patch_retriangulation_required?(patch)
            unless required
              rebuilt_records.concat(patch)
              preserved_patches += 1
              next
            end

            replacement, patch_report = retriangulate_exact_coplanar_patch(patch)
            rebuilt_records.concat(replacement)
            rebuilt_patches += 1
            forced_patches += 1 if forced
            source_triangle_count += patch.length
            rebuilt_triangle_count += replacement.length
            boundary_loop_count += patch_report[:boundary_loops]
            hole_count += patch_report[:holes]
          end

          [
            rebuilt_records,
            {
              detected_patches: patches.length,
              rebuilt_patches: rebuilt_patches,
              preserved_patches: preserved_patches,
              forced_patches: forced_patches,
              forced_source_face_keys: forced_keys.keys,
              source_triangles: source_triangle_count,
              rebuilt_triangles: rebuilt_triangle_count,
              boundary_loops: boundary_loop_count,
              holes: hole_count
            }
          ]
        end
      end
    end
  end
end
