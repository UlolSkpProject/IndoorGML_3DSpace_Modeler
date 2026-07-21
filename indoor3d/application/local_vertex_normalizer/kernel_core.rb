# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Normalizes the vertices of one SketchUp group/component in its own
      # definition-local coordinate system.
      #
      # This class is deliberately independent from SketchUp's active edit path.
      # It reads and writes entity.definition.entities directly and never enters
      # or exits edit mode.
      #
      # The solid is rebuilt instead of moving existing vertices. Direct vertex
      # moves can leave topologically distinct vertices at the same coordinate,
      # which may collapse exported GML rings even when SketchUp still reports a
      # manifold solid.
      class LocalVertexNormalizer
        DEFAULT_TOLERANCE_MM = 0.001

        # Numerical comparison epsilon. This is not the normalization grid size.
        GRID_EPSILON_MM = 0.000001

        STRICT_COPLANAR_TOLERANCE_MM = 0.0001
        STRICT_COPLANAR_ANGLE_TOLERANCE_DEG = 0.001

        COPLANAR_TOLERANCE_MM = 0.01
        COPLANAR_ANGLE_TOLERANCE_DEG = 0.01
        AXIS_PLANE_ANGLE_TOLERANCE_DEG = COPLANAR_ANGLE_TOLERANCE_DEG

        COLLINEAR_CROSS_EPSILON_IN2 = 1.0e-12
        MAX_STITCH_REPAIRS = 1_000
        MAX_COPLANAR_PASSES = 20
        SIGNED_VOLUME_EPSILON_IN3 = 1.0e-12
        MM_PER_INCH = 25.4

        SHORT_EDGE_SLIVER_THRESHOLD_MM = 1.0
        SHORT_EDGE_SLIVER_MIN_ASPECT_RATIO = 20.0
        SHORT_EDGE_SLIVER_PARALLEL_ANGLE_DEG = 1.0
        SHORT_EDGE_SLIVER_LENGTH_RELATIVE_TOLERANCE = 0.05
        SHORT_EDGE_SLIVER_MIN_PATCH_FACES = 2
        SHORT_EDGE_SLIVER_MAX_CLUSTER_DIAMETER_MM = 1.0

        class Error < StandardError; end
        class ReconstructionError < Error; end
        class DestructiveCoplanarCleanupError < ReconstructionError; end
        class TopologyChangedError < Error; end
        class OperationError < Error; end

        class << self
          def normalized?(entity, tolerance_mm = DEFAULT_TOLERANCE_MM)
            new(tolerance_mm).normalized?(entity)
          end
        end

        def initialize(
          tolerance_mm = DEFAULT_TOLERANCE_MM,
          point_factory: nil,
          vector_factory: nil,
          edge_class: nil,
          face_class: nil,
          model: nil
        )
          @tolerance_mm = Float(tolerance_mm)
          unless @tolerance_mm.positive?
            raise ArgumentError, 'Local vertex normalize tolerance must be greater than zero'
          end

          @point_factory = point_factory || ->(x, y, z) { Geom::Point3d.new(x, y, z) }
          @vector_factory = vector_factory || ->(x, y, z) { Geom::Vector3d.new(x, y, z) }
          @edge_class = edge_class || Sketchup::Edge
          @face_class = face_class || Sketchup::Face
          @model = model
        rescue TypeError, ArgumentError => e
          raise e if e.is_a?(ArgumentError) && e.message.include?('greater than zero')

          raise ArgumentError, "Invalid local vertex normalize tolerance: #{tolerance_mm.inspect}"
        end

        private

        # commit_on_failure is a development-only inspection aid. It preserves
        # every mutation made before a reconstruction exception, then re-raises
        # that original exception. The safe production default remains rollback.
        def with_normalization_operation(entity, commit_on_failure: false)
          model = normalization_model(entity)
          operation_started = false
          commit_attempted = false

          begin
            operation_started = model.start_operation(
              'Normalize IndoorGML local vertices',
              true
            )
            unless operation_started
              raise OperationError, 'Failed to start local vertex normalization operation'
            end

            result = yield
            commit_attempted = true
            committed = model.commit_operation
            if committed == false
              raise OperationError, 'Failed to commit local vertex normalization operation'
            end

            operation_started = false
            result
          rescue StandardError => error
            if operation_started && commit_on_failure && !commit_attempted
              failure_commit_error = commit_failed_normalization_operation(model)
              unless failure_commit_error
                operation_started = false
                raise
              end

              rollback_error = rollback_normalization_operation(model)
              message =
                "Local vertex normalization failed (#{error.class}: #{error.message}) " \
                "and committing the failed state also failed " \
                "(#{failure_commit_error.class}: #{failure_commit_error.message})"
              if rollback_error
                message +=
                  " and rollback failed " \
                  "(#{rollback_error.class}: #{rollback_error.message})"
              end
              raise OperationError, message
            end

            rollback_error = rollback_normalization_operation(model) if operation_started
            if rollback_error
              raise OperationError,
                    "Local vertex normalization failed (#{error.class}: #{error.message}) " \
                    "and rollback failed (#{rollback_error.class}: #{rollback_error.message})"
            end

            raise
          end
        end

        def normalization_model(entity)
          model = @model
          model ||= entity.model if entity.respond_to?(:model)
          if model.nil? && defined?(Sketchup) && Sketchup.respond_to?(:active_model)
            model = Sketchup.active_model
          end

          unless model&.respond_to?(:start_operation) &&
                 model.respond_to?(:commit_operation) &&
                 model.respond_to?(:abort_operation)
            raise OperationError, 'A SketchUp model is required for local vertex normalization'
          end

          model
        rescue OperationError
          raise
        rescue StandardError => e
          raise OperationError, "Could not resolve SketchUp model: #{e.class}: #{e.message}"
        end

        def commit_failed_normalization_operation(model)
          committed = model.commit_operation
          return nil unless committed == false

          OperationError.new('SketchUp returned false from commit_operation')
        rescue StandardError => e
          e
        end

        def rollback_normalization_operation(model)
          aborted = model.abort_operation
          return nil unless aborted == false

          OperationError.new('SketchUp returned false from abort_operation')
        rescue StandardError => e
          e
        end

        def build_normalization_report(
          entity:,
          topology_before:,
          topology_after:,
          volume_before_mm3:,
          source_vertices:,
          final_vertices:,
          vertex_metrics:,
          source_triangles:,
          conforming_triangles:,
          degenerate_repair:,
          build:,
          mesh_validation:,
          final_mesh_validation:,
          orientation:,
          axis_plane_plan:,
          axis_plane_merge:,
          short_edge_sliver_repair:,
          planar_patch_retriangulation:,
          duplicate_diagnostics:,
          residual_mm:
        )
          {
            persistent_id: entity.respond_to?(:persistent_id) ? entity.persistent_id : nil,
            name: entity.respond_to?(:name) ? entity.name.to_s : '',
            tolerance_mm: @tolerance_mm,
            coplanar_tolerance_mm: COPLANAR_TOLERANCE_MM,
            axis_plane_angle_tolerance_deg: AXIS_PLANE_ANGLE_TOLERANCE_DEG,
            axis_plane_grouping: :shared_edge_connectivity,
            vertex_count: source_vertices.length,
            unique_normalized_vertex_count: vertex_metrics[:unique_target_count],
            moved_vertex_count: vertex_metrics[:moved_count],
            merged_vertex_count: source_vertices.length - final_vertices.length,
            max_displacement_mm: [
              vertex_metrics[:max_displacement_mm],
              short_edge_sliver_repair[:max_displacement_mm]
            ].compact.max || 0.0,
            max_grid_residual_mm: residual_mm,
            max_unprotected_grid_residual_mm: residual_mm,
            protected_coincident_vertex_count: 0,
            normalization_complete: true,
            normalization_passes: [
              {
                phase: :axis_plane_constraints,
                constrained_faces: axis_plane_plan[:face_count],
                constrained_vertices: axis_plane_plan[:constrained_vertex_count],
                plane_clusters: axis_plane_plan[:cluster_count],
                max_plane_displacement_mm: axis_plane_plan[:max_displacement_mm],
                axis_cluster_counts: axis_plane_plan[:axis_cluster_counts]
              },
              {
                phase: :short_edge_sliver_patch_collapse,
                threshold_mm: SHORT_EDGE_SLIVER_THRESHOLD_MM,
                detected_faces: short_edge_sliver_repair[:detected_face_count],
                repairable_patches: short_edge_sliver_repair[:repairable_patch_count],
                repaired_faces: short_edge_sliver_repair[:repaired_face_count],
                collapsed_clusters: short_edge_sliver_repair[:collapsed_cluster_count],
                collapsed_vertices: short_edge_sliver_repair[:collapsed_vertex_count],
                removed_degenerate_triangles:
                  short_edge_sliver_repair[:removed_degenerate_triangle_count],
                removed_duplicate_triangles:
                  short_edge_sliver_repair[:removed_duplicate_triangle_count],
                max_displacement_mm: short_edge_sliver_repair[:max_displacement_mm],
                euler_characteristic_before:
                  short_edge_sliver_repair[:euler_characteristic_before],
                euler_characteristic_after:
                  short_edge_sliver_repair[:euler_characteristic_after],
                skipped_patches: short_edge_sliver_repair[:skipped_patches]
              },
              {
                phase: :degenerate_triangle_retriangulation,
                repaired_triangles: degenerate_repair[:repaired_triangles],
                replaced_pairs: degenerate_repair[:replaced_pairs],
                stages: degenerate_repair[:stages]
              },
              {
                phase: :exact_coplanar_patch_retriangulation,
                detected_patches: planar_patch_retriangulation[:detected_patches],
                rebuilt_patches: planar_patch_retriangulation[:rebuilt_patches],
                preserved_patches: planar_patch_retriangulation[:preserved_patches],
                source_triangles: planar_patch_retriangulation[:source_triangles],
                rebuilt_triangles: planar_patch_retriangulation[:rebuilt_triangles],
                boundary_loops: planar_patch_retriangulation[:boundary_loops],
                holes: planar_patch_retriangulation[:holes]
              },
              {
                phase: :validated_triangle_rebuild,
                source_triangles: conforming_triangles.length,
                added_faces: build[:added_faces],
                skipped_collinear: build[:skipped_collinear],
                validated_vertices: mesh_validation[:vertex_count],
                validated_edges: mesh_validation[:edge_count],
                validated_components: mesh_validation[:component_count],
                tested_triangle_pairs: mesh_validation[:tested_triangle_pairs]
              },
              {
                phase: :axis_plane_face_merge,
                removed_internal_edges: axis_plane_merge[:removed_edges],
                merged_faces: axis_plane_merge[:merged_faces],
                passes: axis_plane_merge[:passes]
              },
              {
                phase: :exact_duplicate_triangle_canonicalization,
                source_duplicates: duplicate_diagnostics.dig(:source, :duplicate_count).to_i,
                rebuilt_duplicates: duplicate_diagnostics.dig(:rebuilt, :duplicate_count).to_i,
                final_duplicates: duplicate_diagnostics.dig(:final, :duplicate_count).to_i
              },
              {
                phase: :face_orientation,
                reversed_faces: orientation[:reversed_faces],
                consistency_reversed_faces: orientation[:consistency_reversed_faces],
                shell_component_count: orientation[:shell_component_count],
                outward_reversed_faces: orientation[:outward_reversed_faces],
                signed_volume_before_mm3: orientation[:signed_volume_before_mm3],
                signed_volume_after_mm3: orientation[:signed_volume_after_mm3]
              }
            ],
            source_triangle_count: source_triangles.length,
            conforming_triangle_count: conforming_triangles.length,
            degenerate_triangle_repair_count: degenerate_repair[:repaired_triangles],
            degenerate_triangle_replaced_pair_count: degenerate_repair[:replaced_pairs],
            added_face_count: build[:added_faces],
            skipped_collinear_triangle_count: build[:skipped_collinear],
            final_triangle_count: final_mesh_validation[:triangle_count],
            surface_border_repair_count: 0,
            redundant_overlap_triangle_removal_count: 0,
            strict_coplanar_edge_removal_count: axis_plane_merge[:removed_edges],
            coplanar_edge_removal_count: axis_plane_merge[:removed_edges],
            axis_plane_internal_edge_removal_count: axis_plane_merge[:removed_edges],
            axis_plane_merged_face_count: axis_plane_merge[:merged_faces],
            duplicate_normalized_triangle_removal_count: duplicate_diagnostics.values.sum do |entry|
              entry[:duplicate_count].to_i
            end,
            duplicate_normalized_triangle_samples: duplicate_diagnostics.transform_values do |entry|
              entry[:samples] || []
            end,
            collinear_vertex_removal_count: 0,
            short_edge_sliver_threshold_mm: SHORT_EDGE_SLIVER_THRESHOLD_MM,
            short_edge_sliver_detected_face_count:
              short_edge_sliver_repair[:detected_face_count],
            short_edge_sliver_repaired_face_count:
              short_edge_sliver_repair[:repaired_face_count],
            short_edge_sliver_collapsed_vertex_count:
              short_edge_sliver_repair[:collapsed_vertex_count],
            short_edge_sliver_removed_triangle_count:
              short_edge_sliver_repair[:removed_degenerate_triangle_count] +
              short_edge_sliver_repair[:removed_duplicate_triangle_count],
            reoriented_face_count: orientation[:reversed_faces],
            max_coplanar_plane_deviation_mm: 0.0,
            max_coplanar_angle_deg: 0.0,
            axis_plane_face_count: axis_plane_plan[:face_count],
            axis_plane_cluster_count: axis_plane_plan[:cluster_count],
            axis_plane_constrained_vertex_count: axis_plane_plan[:constrained_vertex_count],
            max_axis_plane_displacement_mm: axis_plane_plan[:max_displacement_mm],
            normalization_strategy: :validated_triangle_rebuild,
            direct_vertex_move_fallback: nil,
            coplanar_cleanup_fallback: nil,
            heuristic_repairs_enabled:
              short_edge_sliver_repair[:collapsed_vertex_count].positive?,
            volume_before_mm3: volume_before_mm3,
            volume_after_mm3: solid_volume_mm3(entity),
            topology_before: topology_before,
            topology: topology_after,
            topology_changed: topology_before != topology_after,
            manifold: true
          }
        end

        def empty_coplanar_cleanup_report(fallback_reason: nil)
          {
            removed_edges: 0,
            unchanged_edges: 0,
            passes: [],
            max_plane_deviation_mm: 0.0,
            max_angle_deg: 0.0,
            fallback_reason: fallback_reason
          }
        end
      end
    end
  end
end
