# frozen_string_literal: true

require_relative 'axis_and_triangle_policy_v2'
require_relative 'rebuild_repair_v2'
require_relative 'report_v2'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Pipeline v2 overrides for LocalVertexNormalizer.
      class LocalVertexNormalizer
        AXIS_CONSTRAINT_PRIORITY = [2, 1, 0].freeze unless const_defined?(:AXIS_CONSTRAINT_PRIORITY, false)
        MAX_EXTERNAL_FACE_REPAIRS = 1_000 unless const_defined?(:MAX_EXTERNAL_FACE_REPAIRS, false)

        class << self
          # Production normalization always rolls back on failure. Failed-state
          # commits remain unavailable through the public API.
          def normalize(
            entity,
            tolerance_mm = DEFAULT_TOLERANCE_MM,
            commit_on_failure: false,
            debug: false,
            report: false,
            report_path: nil,
            write_report: true,
            manage_operation: true
          )
            if commit_on_failure
              raise ArgumentError,
                    'commit_on_failure is disabled for LocalVertexNormalizer v2'
            end

            new(tolerance_mm).normalize(
              entity,
              debug: debug,
              report: report,
              report_path: report_path,
              write_report: write_report,
              manage_operation: manage_operation
            )
          end

          def normalized?(entity, tolerance_mm = DEFAULT_TOLERANCE_MM)
            new(tolerance_mm).normalized?(entity)
          end
        end

        def normalize(
          entity,
          commit_on_failure: false,
          manage_operation: true
        )
          if commit_on_failure
            raise ArgumentError,
                  'commit_on_failure is disabled for LocalVertexNormalizer v2'
          end

          validate_entity!(entity)
          return normalize_entity(entity) unless manage_operation

          with_normalization_operation(entity, commit_on_failure: false) do
            normalize_entity(entity)
          end
        end

        # Coincident topological vertices are allowed when every coordinate is
        # already normalized. Final topology is decided by normalize's hard gate.
        def normalized?(entity)
          return false unless valid_entity_definition?(entity)

          entities = entity.definition.entities
          vertices = geometry_vertices(entities)
          return false if vertices.empty?

          axis_plane_plan = axis_plane_normalization_plan(entities)
          vertices.each do |vertex|
            point = vertex.position
            return false unless point_on_grid?(point)

            target = normalized_target(point, axis_plane_plan)
            return false if point_distance_mm(point, target) > GRID_EPSILON_MM
          end

          return false if short_edge_sliver_collapse_plan(
            entities,
            axis_plane_plan
          )[:repairable]

          true
        rescue StandardError
          false
        end

        private

        # Full v2 sequence:
        # 1. validate source solid
        # 2. build independent X/Y/Z axis-plane targets
        # 3. compute grid targets and allow collisions
        # 4. discard triangles collapsed by source/grid transformations
        # 5. collapse supported sliver patches
        # 6. validate the complete in-memory triangle mesh
        # 7. rebuild SketchUp geometry
        # 8. orient faces and remove safe coplanar internal edges
        # 9. attempt bounded entity repairs, require manifold and exact surface equality
        def normalize_entity(entity)
          ensure_unique_definition(entity)

          entities = entity.definition.entities
          topology_before = geometry_counts(entities)
          volume_before_mm3 = solid_volume_mm3(entity)
          source_vertices = geometry_vertices(entities)

          axis_plane_plan = axis_plane_normalization_plan(entities)
          vertex_metrics = normalized_vertex_metrics(source_vertices, axis_plane_plan)
          short_edge_sliver_plan = short_edge_sliver_collapse_plan(
            entities,
            axis_plane_plan
          )

          @source_boundary_axis_plane_plan_v2 = axis_plane_plan
          begin
            source_space_triangles = triangle_snapshot(entities)
          ensure
            @source_boundary_axis_plane_plan_v2 = nil
          end
          source_boundary_normalization =
            (@source_boundary_normalization_stats_v2 || {}).dup
          source_conforming_duplicate_diagnostics = {}
          # Preserve source vertex-on-edge incidence before independent grid
          # rounding can bend a formerly collinear shared boundary. The target
          # mesh then carries the same A-B/B-C subdivision even when B no longer
          # lies exactly on the rounded A-C segment.
          source_space_triangles = conforming_triangle_snapshot(
            source_space_triangles,
            coordinate_space: :source,
            duplicate_diagnostics: source_conforming_duplicate_diagnostics
          )
          source_space_triangles, source_altitude_sliver_collapse =
            collapse_source_altitude_sliver_triangles(
              source_space_triangles
            )
          source_space_triangles = conforming_triangle_snapshot(
            source_space_triangles,
            coordinate_space: :source,
            duplicate_diagnostics: source_conforming_duplicate_diagnostics
          )
          source_space_triangles, pre_normalization_triangle_cleanup =
            discard_collapsed_triangle_records(
              source_space_triangles,
              coordinate_space: :source
            )

          source_duplicate_diagnostics = {}
          source_triangles, target_collision_cleanup =
            normalize_triangle_records_allowing_collisions(
              source_space_triangles,
              axis_plane_plan,
              duplicate_diagnostics: source_duplicate_diagnostics
            )
          source_triangles, source_triangle_cleanup =
            discard_collapsed_triangle_records(source_triangles)
          validate_normalized_triangle_shapes!(source_triangles)

          grid_conforming_duplicate_diagnostics = {}
          conforming_triangles = conforming_triangle_snapshot(
            source_triangles,
            duplicate_diagnostics: grid_conforming_duplicate_diagnostics
          )
          conforming_triangles, conforming_triangle_cleanup =
            discard_collapsed_triangle_records(conforming_triangles)
          if conforming_triangles.empty?
            raise ReconstructionError,
                  "No reconstructable faces found for #{entity_label(entity)}"
          end

          baseline_mesh_inventory = triangle_mesh_inventory(conforming_triangles)
          conforming_triangles, short_edge_sliver_repair =
            collapse_short_edge_sliver_triangles(
              conforming_triangles,
              short_edge_sliver_plan,
              baseline_mesh_inventory
          )
          if short_edge_sliver_repair[:repairable]
            conforming_triangles, post_sliver_cleanup =
              discard_collapsed_triangle_records(conforming_triangles)
          else
            post_sliver_cleanup = empty_triangle_cleanup_report
          end
          merge_triangle_cleanup_reports!(
            short_edge_sliver_repair,
            post_sliver_cleanup
          )

          # This is the hard pre-mutation gate. All target collisions, triangle
          # deletions, and sliver changes must form one exact
          # closed, non-self-intersecting shell before source geometry is erased.
          mesh_validation = validate_normalized_triangle_mesh!(conforming_triangles)
          validate_sliver_topology_when_comparable!(
            baseline_mesh_inventory,
            mesh_validation,
            short_edge_sliver_repair
          )

          erase_source_geometry(entities)
          build = rebuild_triangles(entities, conforming_triangles)
          build[:expected_faces] = conforming_triangles.length
          build[:complete] = build[:added_faces] == conforming_triangles.length &&
            build[:skipped_collinear].zero?
          build[:requires_final_equivalence_validation] = !build[:complete]
          if build[:added_faces].to_i.zero?
            raise ReconstructionError,
                  "Normalized triangle rebuild created no faces: #{build.inspect}"
          end

          rebuilt_duplicate_diagnostics = {}
          rebuilt_triangle_cleanup = empty_triangle_cleanup_report
          rebuilt_pre_repair_validation = { valid: false }
          begin
            rebuilt_triangles = normalized_triangle_snapshot(
              entities,
              duplicate_diagnostics: rebuilt_duplicate_diagnostics,
              snapshot_role: :rebuilt_pre_cleanup
            )
            rebuilt_triangles, rebuilt_triangle_cleanup =
              discard_collapsed_triangle_records(rebuilt_triangles)
            rebuilt_mesh_validation =
              validate_normalized_triangle_mesh!(rebuilt_triangles)
            verify_triangle_rebuild!(conforming_triangles, rebuilt_triangles)
            rebuilt_pre_repair_validation = {
              valid: true,
              mesh: rebuilt_mesh_validation,
              matches_validated_input: true
            }
          rescue Error, ArgumentError => error
            rebuilt_pre_repair_validation = {
              valid: false,
              matches_validated_input: false,
              error: "#{error.class}: #{error.message}",
              topology: geometry_counts(entities)
            }
          end

          orientation, axis_plane_merge, post_cleanup_snapshot =
            orient_and_merge_rebuilt_surface(entities, conforming_triangles)

          final_repair = repair_rebuilt_entity_before_rollback(entity, entities)
          topology_after = geometry_counts(entities)
          validate_rebuilt_entity!(entity, topology_after)

          final_vertices = geometry_vertices(entities)
          residual_mm = max_grid_residual_mm(final_vertices)
          if residual_mm > GRID_EPSILON_MM
            raise TopologyChangedError,
                  "Rebuilt vertices are off the #{@tolerance_mm} mm grid: " \
                  "residual=#{residual_mm} mm"
          end

          final_duplicate_diagnostics = {}
          final_state = final_normalized_mesh_state(
            entities,
            conforming_triangles,
            final_repair,
            topology_after,
            post_cleanup_snapshot,
            final_duplicate_diagnostics
          )
          final_triangles,
            final_triangle_cleanup,
            final_mesh_validation,
            final_surface_equivalence,
            snapshot_reuse = final_state

          triangle_cleanup = aggregate_triangle_cleanup_reports(
            pre_normalization: pre_normalization_triangle_cleanup,
            target_projection: target_collision_cleanup,
            source: source_triangle_cleanup,
            conforming: conforming_triangle_cleanup,
            post_sliver: post_sliver_cleanup,
            rebuilt: rebuilt_triangle_cleanup,
            final: final_triangle_cleanup
          )

          report = build_normalization_report(
            entity: entity,
            topology_before: topology_before,
            topology_after: topology_after,
            volume_before_mm3: volume_before_mm3,
            source_vertices: source_vertices,
            final_vertices: final_vertices,
            vertex_metrics: vertex_metrics,
            source_triangles: source_triangles,
            conforming_triangles: conforming_triangles,
            degenerate_repair: triangle_cleanup,
            build: build,
            mesh_validation: mesh_validation,
            final_mesh_validation: final_mesh_validation,
            orientation: orientation,
            axis_plane_plan: axis_plane_plan,
            axis_plane_merge: axis_plane_merge,
            short_edge_sliver_repair: short_edge_sliver_repair,
            duplicate_diagnostics: {
              source: source_duplicate_diagnostics,
              source_conforming: source_conforming_duplicate_diagnostics,
              grid_conforming: grid_conforming_duplicate_diagnostics,
              rebuilt: rebuilt_duplicate_diagnostics,
              final: final_duplicate_diagnostics
            },
            residual_mm: residual_mm
          )

          augment_v2_normalization_report!(
            report,
            axis_plane_plan: axis_plane_plan,
            vertex_metrics: vertex_metrics,
            target_collision_cleanup: target_collision_cleanup,
            triangle_cleanup: triangle_cleanup,
            rebuilt_pre_repair_validation: rebuilt_pre_repair_validation,
            final_surface_equivalence: final_surface_equivalence,
            final_repair: final_repair,
            source_boundary_normalization: source_boundary_normalization,
            source_altitude_sliver_collapse:
              source_altitude_sliver_collapse
          )
          report[:snapshot_reuse] = snapshot_reuse
          report
        end

        # Returns the unchanged-result report for a skipped triangle cleanup.
        def empty_triangle_cleanup_report
          {
            removed_coincident_triangle_count: 0,
            removed_collinear_triangle_count: 0,
            removed_duplicate_triangle_count: 0,
            affected_source_face_keys: [],
            skipped: true
          }
        end

        def final_normalized_mesh_state(
          entities,
          expected_triangles,
          final_repair,
          topology_after,
          post_cleanup_snapshot,
          duplicate_diagnostics
        )
          reuse_decision = post_cleanup_snapshot_reuse_decision(
            post_cleanup_snapshot,
            final_repair,
            topology_after
          )
          if reuse_decision[:reused]
            duplicate_diagnostics.merge!(
              post_cleanup_snapshot.fetch(:duplicate_diagnostics)
            )
            duplicate_diagnostics[:reused_post_cleanup_snapshot] = true
            equivalence = post_cleanup_snapshot.fetch(:surface_equivalence).dup
            equivalence[:final_snapshot_reused] = true
            return [
              post_cleanup_snapshot.fetch(:triangles),
              post_cleanup_snapshot.fetch(:degenerate_repair),
              post_cleanup_snapshot.fetch(:mesh_validation),
              equivalence,
              reuse_decision
            ]
          end

          duplicate_diagnostics[:reused_post_cleanup_snapshot] = false
          final_triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: duplicate_diagnostics,
            snapshot_role: :final_fallback
          )
          final_triangles, final_triangle_cleanup =
            discard_collapsed_triangle_records(final_triangles)
          final_mesh_validation =
            validate_normalized_triangle_mesh!(final_triangles)
          final_surface_equivalence = verify_normalized_surface_equivalence!(
            expected_triangles,
            final_triangles
          )
          final_surface_equivalence = final_surface_equivalence.dup
          final_surface_equivalence[:final_snapshot_reused] = false
          [
            final_triangles,
            final_triangle_cleanup,
            final_mesh_validation,
            final_surface_equivalence,
            reuse_decision
          ]
        end

        def reusable_post_cleanup_snapshot?(
          snapshot,
          final_repair,
          topology_after
        )
          post_cleanup_snapshot_reuse_decision(
            snapshot,
            final_repair,
            topology_after
          )[:reused]
        end

        def post_cleanup_snapshot_reuse_decision(
          snapshot,
          final_repair,
          topology_after
        )
          snapshot_available = snapshot.is_a?(Hash)
          snapshot_validated = snapshot_available && snapshot[:validated] == true
          final_repair_available = final_repair.is_a?(Hash)
          final_repair_attempted = final_repair_available ? final_repair[:attempted] : nil
          final_repair_manifold = final_repair_available ? final_repair[:manifold] : nil
          repair_topology_same = if final_repair_available
                                   final_repair[:initial_topology] ==
                                     final_repair[:final_topology]
                                 end
          post_cleanup_topology_same_as_final = if snapshot_available
                                                  snapshot[:topology] == topology_after
                                                end

          rejection_reasons = []
          rejection_reasons << :post_cleanup_snapshot_missing unless snapshot_available
          rejection_reasons << :post_cleanup_snapshot_not_validated if
            snapshot_available && !snapshot_validated
          rejection_reasons << :final_repair_report_missing unless final_repair_available
          if final_repair_available
            rejection_reasons << :final_repair_attempted unless
              final_repair_attempted == false
            rejection_reasons << :final_entity_not_manifold unless
              final_repair_manifold == true
            rejection_reasons << :final_repair_topology_changed unless
              repair_topology_same
          end
          rejection_reasons << :post_cleanup_topology_changed if
            snapshot_available && !post_cleanup_topology_same_as_final

          {
            reused: rejection_reasons.empty?,
            rejection_reasons: rejection_reasons,
            post_cleanup_snapshot_available: snapshot_available,
            post_cleanup_snapshot_validated: snapshot_validated,
            final_repair_report_available: final_repair_available,
            final_repair_attempted: final_repair_attempted,
            final_repair_manifold: final_repair_manifold,
            repair_topology_same: repair_topology_same,
            post_cleanup_topology_same_as_final:
              post_cleanup_topology_same_as_final
          }
        end

        def aggregate_triangle_cleanup_reports(stage_reports)
          stages = stage_reports.transform_values do |report|
            {
              removed_coincident_triangle_count:
                report[:removed_coincident_triangle_count].to_i,
              removed_collinear_triangle_count:
                report[:removed_collinear_triangle_count].to_i,
              removed_duplicate_triangle_count:
                report[:removed_duplicate_triangle_count].to_i,
              affected_source_face_keys:
                Array(report[:affected_source_face_keys])
            }
          end
          {
            removed_coincident_triangle_count: stages.values.sum do |stage|
              stage[:removed_coincident_triangle_count]
            end,
            removed_collinear_triangle_count: stages.values.sum do |stage|
              stage[:removed_collinear_triangle_count]
            end,
            removed_duplicate_triangle_count: stages.values.sum do |stage|
              stage[:removed_duplicate_triangle_count]
            end,
            affected_source_face_keys: stages.values.flat_map do |stage|
              stage[:affected_source_face_keys]
            end.compact.uniq,
            stages: stages,
            # Compatibility fields: the removal-only policy performs no repair.
            repaired_triangles: 0,
            replaced_pairs: 0
          }
        end
      end
    end
  end
end
