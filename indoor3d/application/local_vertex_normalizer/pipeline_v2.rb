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
            commit_on_failure: false
          )
            if commit_on_failure
              raise ArgumentError,
                    'commit_on_failure is disabled for LocalVertexNormalizer v2'
            end

            new(tolerance_mm).normalize(entity)
          end

          def normalized?(entity, tolerance_mm = DEFAULT_TOLERANCE_MM)
            new(tolerance_mm).normalized?(entity)
          end
        end

        def normalize(entity, commit_on_failure: false)
          if commit_on_failure
            raise ArgumentError,
                  'commit_on_failure is disabled for LocalVertexNormalizer v2'
          end

          validate_entity!(entity)
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
        # 4. locally repair triangles and mark unresolved neighborhoods
        # 5. collapse supported sliver patches
        # 6. force affected coplanar patches through full retriangulation
        # 7. validate the complete in-memory triangle mesh
        # 8. rebuild SketchUp geometry
        # 9. orient faces and remove safe coplanar internal edges
        # 10. attempt bounded repairs, require manifold and exact surface equality
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

          source_space_triangles = triangle_snapshot(entities)
          source_space_triangles, pre_normalization_degenerate_repair =
            repair_degenerate_source_triangles(
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
          source_triangles, source_degenerate_repair =
            repair_grid_triangles_with_patch_fallback(source_triangles)
          validate_normalized_triangle_shapes!(source_triangles)

          conforming_triangles = conforming_triangle_snapshot(source_triangles)
          conforming_triangles, conforming_degenerate_repair =
            repair_grid_triangles_with_patch_fallback(conforming_triangles)
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
          conforming_triangles, post_sliver_cleanup =
            sanitize_triangle_records(conforming_triangles)
          merge_triangle_cleanup_reports!(
            short_edge_sliver_repair,
            post_sliver_cleanup
          )

          forced_retriangulation = collect_forced_retriangulation_keys(
            target_collision_cleanup,
            source_degenerate_repair,
            conforming_degenerate_repair,
            post_sliver_cleanup,
            short_edge_sliver_plan
          )
          conforming_triangles, planar_patch_retriangulation =
            retriangulate_exact_coplanar_patches(
              conforming_triangles,
              forced_source_face_keys: forced_retriangulation[:source_face_keys]
            )
          conforming_triangles, post_retriangulation_cleanup =
            sanitize_triangle_records(conforming_triangles)

          # Step 7 is the hard pre-mutation gate. All target collisions, local
          # repairs, sliver changes, and forced patch rebuilds must form one exact
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
          rebuilt_degenerate_repair = {
            repaired_triangles: 0,
            replaced_pairs: 0
          }
          rebuilt_pre_repair_validation = { valid: false }
          begin
            rebuilt_triangles = normalized_triangle_snapshot(
              entities,
              duplicate_diagnostics: rebuilt_duplicate_diagnostics
            )
            rebuilt_triangles, rebuilt_degenerate_repair =
              repair_degenerate_source_triangles(rebuilt_triangles)
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

          orientation, axis_plane_merge =
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
          final_triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: final_duplicate_diagnostics
          )
          final_triangles, final_degenerate_repair =
            repair_degenerate_source_triangles(final_triangles)
          final_mesh_validation = validate_normalized_triangle_mesh!(final_triangles)
          final_surface_equivalence = verify_normalized_surface_equivalence!(
            conforming_triangles,
            final_triangles
          )

          degenerate_repair = aggregate_degenerate_repair_reports(
            pre_normalization: pre_normalization_degenerate_repair,
            source: source_degenerate_repair,
            conforming: conforming_degenerate_repair,
            rebuilt: rebuilt_degenerate_repair,
            final: final_degenerate_repair
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
            degenerate_repair: degenerate_repair,
            build: build,
            mesh_validation: mesh_validation,
            final_mesh_validation: final_mesh_validation,
            orientation: orientation,
            axis_plane_plan: axis_plane_plan,
            axis_plane_merge: axis_plane_merge,
            short_edge_sliver_repair: short_edge_sliver_repair,
            planar_patch_retriangulation: planar_patch_retriangulation,
            duplicate_diagnostics: {
              source: source_duplicate_diagnostics,
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
            post_retriangulation_cleanup: post_retriangulation_cleanup,
            rebuilt_pre_repair_validation: rebuilt_pre_repair_validation,
            forced_retriangulation: forced_retriangulation,
            final_surface_equivalence: final_surface_equivalence,
            final_repair: final_repair
          )
          report
        end

        def collect_forced_retriangulation_keys(*reports)
          source_face_keys = []
          reasons = Hash.new(0)

          reports.each do |report|
            next unless report.is_a?(Hash)

            keys = Array(report[:forced_source_face_keys]) +
              Array(report[:affected_source_face_keys])
            unless keys.empty?
              source_face_keys.concat(keys)
              reasons[:triangle_repair_or_cleanup] += keys.length
            end

            next unless report[:repairable]

            Array(report[:candidates]).each do |candidate|
              source_face_keys << candidate[:face_key]
              source_face_keys.concat(Array(candidate[:support_face_keys]))
            end
            reasons[:sliver_patch] += Array(report[:candidates]).length
          end

          {
            source_face_keys: source_face_keys.compact.uniq,
            reasons: reasons
          }
        end
      end
    end
  end
end
