# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # A vertex can be present in more than one axis-aligned face family. V2
        # assigns one owner constraint using Z -> Y -> X. Multiple candidates on
        # the same winning axis are resolved by minimum source displacement,
        # rather than aborting the complete normalization.
        def axis_plane_normalization_plan(entities)
          records = entities.grep(@face_class).filter_map do |face|
            axis_plane_face_record(face)
          end
          clusters = []
          candidates_by_point = Hash.new { |hash, key| hash[key] = [] }

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
                key = source_point_key(vertex.position)
                source_coordinate_mm = point_coordinate(vertex.position, axis) * MM_PER_INCH
                candidates_by_point[key] << {
                  axis: axis,
                  target_index: target_index,
                  displacement_mm: (source_coordinate_mm - target_mm).abs,
                  cluster: cluster
                }
              end
            end
          end

          constraints = {}
          resolved_conflicts = []
          discarded_count = 0

          candidates_by_point.each do |point_key, candidates|
            selected = candidates.min_by do |candidate|
              [
                AXIS_CONSTRAINT_PRIORITY.index(candidate[:axis]) || AXIS_CONSTRAINT_PRIORITY.length,
                candidate[:displacement_mm],
                candidate[:target_index]
              ]
            end
            constraints[point_key] = { selected[:axis] => selected[:target_index] }

            discarded = candidates.reject { |candidate| candidate.equal?(selected) }
            next if discarded.empty?

            discarded_count += discarded.length
            resolved_conflicts << {
              point: point_key,
              selected_axis: selected[:axis],
              selected_target_index: selected[:target_index],
              discarded: discarded.map do |candidate|
                {
                  axis: candidate[:axis],
                  target_index: candidate[:target_index],
                  displacement_mm: candidate[:displacement_mm]
                }
              end
            }
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
            max_displacement_mm: max_displacement_mm,
            axis_cluster_counts: clusters.group_by { |cluster| cluster[:axis] }
                                         .transform_values(&:length),
            axis_priority: AXIS_CONSTRAINT_PRIORITY.dup,
            resolved_constraint_conflicts: resolved_conflicts,
            resolved_constraint_conflict_count: resolved_conflicts.length,
            discarded_constraint_count: discarded_count
          }
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

        # Applies target coordinates without treating coincident vertices as an
        # immediate error. Triangles whose vertices collapse to fewer than three
        # positions are removed here; all remaining topology is validated before
        # any SketchUp entity is erased.
        def normalize_triangle_records_allowing_collisions(
          triangle_records,
          axis_plane_plan = nil,
          duplicate_diagnostics: nil
        )
          records = triangle_records.map do |source_record|
            source_record.merge(
              points: source_record[:points].map do |point|
                normalized_target(point, axis_plane_plan)
              end
            )
          end
          sanitized, cleanup = sanitize_triangle_records(
            records,
            duplicate_diagnostics: duplicate_diagnostics,
            remove_collinear: false
          )
          [sanitized, cleanup]
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

          records = triangle_records.filter_map do |record|
            triangle = record[:points].map { |point| grid_indices(point) }
            if triangle.uniq.length != 3
              removed_coincident += 1
              next
            end
            if remove_collinear && integer_zero_vector?(integer_triangle_normal(triangle))
              removed_collinear += 1
              next
            end

            signature = canonical_triangle_key(triangle)
            if signatures.key?(signature)
              removed_duplicate += 1
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
              removed_duplicate_triangle_count: removed_duplicate
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

        def repair_grid_triangles_with_patch_fallback(triangle_records)
          repair_degenerate_source_triangles(triangle_records)
        rescue ReconstructionError => error
          sanitized, cleanup = sanitize_triangle_records(
            triangle_records,
            remove_collinear: true
          )
          [
            sanitized,
            {
              repaired_triangles: 0,
              replaced_pairs: 0,
              deferred_to_patch_retriangulation: true,
              fallback_reason: "#{error.class}: #{error.message}",
              removed_coincident_triangles:
                cleanup[:removed_coincident_triangle_count],
              removed_collinear_triangles:
                cleanup[:removed_collinear_triangle_count],
              removed_duplicate_triangles:
                cleanup[:removed_duplicate_triangle_count]
            }
          ]
        end
      end
    end
  end
end
