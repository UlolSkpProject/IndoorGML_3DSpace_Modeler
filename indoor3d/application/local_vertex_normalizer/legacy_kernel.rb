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
            operation_started = measure_debug_stage(:operation_start) do
              model.start_operation(
                'Normalize IndoorGML local vertices',
                true
              )
            end
            unless operation_started
              raise OperationError, 'Failed to start local vertex normalization operation'
            end

            result = yield
            commit_attempted = true
            committed = measure_debug_stage(:operation_commit) do
              model.commit_operation
            end
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

            rollback_error = if operation_started
                               measure_debug_stage(:operation_rollback) do
                                 rollback_normalization_operation(model)
                               end
                             end
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

        # ----------------------------------------------------------------------
        # Validation and geometry inventory
        # ----------------------------------------------------------------------

        def valid_entity_definition?(entity)
          entity&.respond_to?(:valid?) && entity.valid? &&
            entity.respond_to?(:definition) && entity.definition&.valid?
        end

        def validate_entity!(entity)
          unless valid_entity_definition?(entity)
            raise ArgumentError, 'Valid SketchUp group or component instance expected'
          end

          return if entity.respond_to?(:manifold?) && entity.manifold? == true

          raise TopologyChangedError,
                "Local vertex normalize requires a manifold solid: #{entity_label(entity)}"
        end

        def validate_rebuilt_entity!(entity, topology)
          valid = entity&.valid? &&
                  entity.respond_to?(:manifold?) && entity.manifold? == true &&
                  closed_topology?(topology)
          return if valid

          raise TopologyChangedError,
                "Local vertex reconstruction damaged topology: " \
                "#{entity_label(entity)} #{topology.inspect}"
        end

        def ensure_unique_definition(entity)
          definition = entity.definition
          return unless definition.respond_to?(:instances)
          return unless Array(definition.instances).length > 1

          if entity.respond_to?(:make_unique)
            entity.make_unique
            return
          end

          raise ArgumentError, 'Shared component definition cannot be normalized independently'
        end

        def geometry_vertices(entities)
          entities.grep(@edge_class).flat_map(&:vertices).uniq
        end

        def geometry_counts(entities)
          edges = entities.grep(@edge_class)
          {
            faces: entities.grep(@face_class).length,
            edges: edges.length,
            vertices: edges.flat_map(&:vertices).uniq.length,
            boundary_edges: edges.count { |edge| edge.faces.length == 1 },
            wire_edges: edges.count { |edge| edge.faces.empty? },
            overused_edges: edges.count { |edge| edge.faces.length > 2 },
            orientation_conflicts: edges.count do |edge|
              next false unless edge.faces.length == 2

              edge.reversed_in?(edge.faces[0]) == edge.reversed_in?(edge.faces[1])
            rescue StandardError
              false
            end
          }
        end

        def closed_topology?(topology)
          closed_surface?(topology) && topology[:orientation_conflicts].to_i.zero?
        end

        def closed_surface?(topology)
          topology[:faces].to_i.positive? &&
            topology[:boundary_edges].to_i.zero? &&
            topology[:wire_edges].to_i.zero? &&
            topology[:overused_edges].to_i.zero?
        end

        def topology_anomaly_score(topology)
          topology[:boundary_edges].to_i +
            topology[:wire_edges].to_i +
            topology[:overused_edges].to_i
        end

        def entity_label(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          persistent_id = entity.respond_to?(:persistent_id) ? entity.persistent_id : nil
          "name=#{name.inspect} persistent_id=#{persistent_id.inspect}"
        rescue StandardError
          entity.class.to_s
        end


        # ----------------------------------------------------------------------
        # Grid projection and triangle snapshots
        # ----------------------------------------------------------------------


        def axis_plane_face_record(face)
          return nil unless face&.valid?

          axis = axis_aligned_normal_axis(face.normal)
          return nil if axis.nil?

          vertices = face.vertices
          return nil if vertices.length < 3

          coordinates_mm = vertices.map do |vertex|
            point_coordinate(vertex.position, axis) * MM_PER_INCH
          end

          {
            face: face,
            axis: axis,
            vertices: vertices,
            vertex_ids: vertices.map { |vertex| stable_entity_id(vertex) },
            edge_ids: face.edges.map { |edge| stable_entity_id(edge) },
            coordinates_mm: coordinates_mm
          }
        rescue StandardError
          nil
        end

        def axis_aligned_normal_axis(normal)
          components = vector_components(normal)
          length = vector_length(components)
          return nil if length <= 0.0

          normalized = components.map { |value| value / length }
          axis = normalized.each_index.max_by { |index| normalized[index].abs }
          cosine = normalized[axis].abs
          threshold = Math.cos(AXIS_PLANE_ANGLE_TOLERANCE_DEG * Math::PI / 180.0)
          cosine + 1.0e-15 >= threshold ? axis : nil
        rescue StandardError
          nil
        end

        def axis_plane_connected_components(records)
          by_edge = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, index|
            record[:edge_ids].each { |edge_id| by_edge[edge_id] << index }
          end

          visited = Array.new(records.length, false)
          records.each_index.filter_map do |seed|
            next if visited[seed]

            visited[seed] = true
            queue = [seed]
            component = []
            until queue.empty?
              index = queue.shift
              record = records[index]
              component << record
              record[:edge_ids].each do |edge_id|
                by_edge[edge_id].each do |neighbor|
                  next if visited[neighbor]

                  visited[neighbor] = true
                  queue << neighbor
                end
              end
            end
            component
          end
        end


        def median_value(values)
          sorted = Array(values).map(&:to_f).sort
          raise ReconstructionError, 'Axis-plane family has no coordinates' if sorted.empty?

          middle = sorted.length / 2
          return sorted[middle] if sorted.length.odd?

          (sorted[middle - 1] + sorted[middle]) / 2.0
        end


        # ----------------------------------------------------------------------
        # Short-edge sliver patch repair
        # ----------------------------------------------------------------------

        # Detects only the strict, topology-safe subset of short-edge geometry:
        # a quadrilateral face with two opposite edges shorter than 1 mm and two
        # much longer, parallel connector edges. At least two such faces must be
        # bounded by the same pair of support faces. This excludes isolated
        # micro-steps such as a single short crease between otherwise valid
        # faces.
        def short_edge_sliver_collapse_plan(entities, axis_plane_plan = nil)
          point_by_key = geometry_vertices(entities).each_with_object({}) do |vertex, points|
            point = normalized_target(vertex.position, axis_plane_plan)
            points[grid_indices(point)] ||= point
          end
          candidates = entities.grep(@face_class).filter_map do |face|
            short_edge_sliver_face_candidate(face, axis_plane_plan)
          end
          patches = candidates.group_by { |candidate| candidate[:support_face_keys] }
                              .values
                              .select do |patch|
            patch.length >= SHORT_EDGE_SLIVER_MIN_PATCH_FACES
          end

          point_targets = {}
          collapsed_clusters = []
          skipped_patches = []
          repaired_faces = []

          patches.each do |patch|
            pairs = patch.flat_map { |candidate| candidate[:short_edge_pairs] }
            target_plan = short_edge_cluster_targets(pairs, point_by_key)
            unless target_plan[:ok]
              skipped_patches << {
                support_face_keys: patch.first[:support_face_keys],
                face_keys: patch.map { |candidate| candidate[:face_key] },
                reason: target_plan[:reason]
              }
              next
            end

            conflict = target_plan[:point_targets].find do |key, point|
              existing = point_targets[key]
              existing && grid_indices(existing) != grid_indices(point)
            end
            if conflict
              skipped_patches << {
                support_face_keys: patch.first[:support_face_keys],
                face_keys: patch.map { |candidate| candidate[:face_key] },
                reason: :conflicting_patch_targets,
                point: conflict.first
              }
              next
            end

            point_targets.merge!(target_plan[:point_targets])
            collapsed_clusters.concat(target_plan[:clusters])
            repaired_faces.concat(patch)
          end

          {
            repairable: !point_targets.empty?,
            detected_face_count: candidates.length,
            repairable_patch_count: patches.length - skipped_patches.length,
            repaired_face_count: repaired_faces.length,
            point_targets: point_targets,
            collapsed_clusters: collapsed_clusters,
            collapsed_cluster_count: collapsed_clusters.length,
            collapsed_vertex_count: collapsed_clusters.sum do |cluster|
              cluster[:members].length - 1
            end,
            max_displacement_mm: collapsed_clusters.flat_map do |cluster|
              cluster[:displacements_mm]
            end.max || 0.0,
            skipped_patches: skipped_patches,
            candidates: candidates
          }
        rescue ReconstructionError
          raise
        rescue StandardError => error
          raise ReconstructionError,
                "Short-edge sliver patch detection failed: " \
                "#{error.class}: #{error.message}"
        end

        def short_edge_sliver_face_candidate(face, axis_plane_plan)
          return nil unless face&.valid?
          return nil if face.respond_to?(:loops) && Array(face.loops).length != 1

          loop = face.respond_to?(:outer_loop) ? face.outer_loop : nil
          vertices = loop&.respond_to?(:vertices) ? loop.vertices : face.vertices
          return nil unless vertices.length == 4

          points = vertices.map do |vertex|
            normalized_target(vertex.position, axis_plane_plan)
          end
          shape = short_edge_sliver_quad_shape(points)
          return nil unless shape

          loop_edges = loop&.respond_to?(:edges) ? loop.edges : face.edges
          edge_by_key = Array(loop_edges).each_with_object({}) do |edge, edges|
            endpoints = edge.vertices.map do |vertex|
              normalized_target(vertex.position, axis_plane_plan)
            end
            next unless endpoints.length == 2

            edge_key = canonical_edge_key(
              grid_indices(endpoints[0]),
              grid_indices(endpoints[1])
            )
            edges[edge_key] = edge
          end

          support_faces = shape[:short_edge_pairs].filter_map do |pair|
            edge = edge_by_key[canonical_edge_key(pair[0], pair[1])]
            next unless edge&.valid?

            others = Array(edge.faces).reject { |owner| owner.equal?(face) }
            next unless others.length == 1

            others.first
          end
          return nil unless support_faces.length == 2

          support_face_keys = support_faces.map { |owner| stable_entity_id(owner) }.sort
          return nil unless support_face_keys.uniq.length == 2

          shape.merge(
            face_key: stable_entity_id(face),
            support_face_keys: support_face_keys
          )
        rescue StandardError
          nil
        end

        def short_edge_sliver_quad_shape(points)
          return nil unless points.length == 4

          edge_points = 4.times.map do |index|
            [points[index], points[(index + 1) % 4]]
          end
          lengths = edge_points.map do |point_a, point_b|
            point_distance_mm(point_a, point_b)
          end
          short_indices = lengths.each_index.select do |index|
            lengths[index] < SHORT_EDGE_SLIVER_THRESHOLD_MM
          end
          return nil unless short_indices.length == 2
          return nil unless (short_indices[0] - short_indices[1]).abs == 2

          long_indices = (0...4).to_a - short_indices
          short_lengths = short_indices.map { |index| lengths[index] }
          long_lengths = long_indices.map { |index| lengths[index] }
          return nil if short_lengths.min <= GRID_EPSILON_MM
          return nil unless long_lengths.min / short_lengths.max >=
                            SHORT_EDGE_SLIVER_MIN_ASPECT_RATIO
          return nil unless similar_segment_lengths?(short_lengths)
          return nil unless similar_segment_lengths?(long_lengths)
          return nil unless parallel_segments?(
            edge_points[short_indices[0]],
            edge_points[short_indices[1]]
          )
          return nil unless parallel_segments?(
            edge_points[long_indices[0]],
            edge_points[long_indices[1]]
          )

          {
            short_edge_pairs: short_indices.map do |index|
              edge_points[index].map { |point| grid_indices(point) }
            end,
            short_edge_lengths_mm: short_lengths,
            long_edge_lengths_mm: long_lengths,
            aspect_ratio: long_lengths.min / short_lengths.max
          }
        end

        def similar_segment_lengths?(lengths)
          minimum, maximum = lengths.minmax
          return false unless maximum&.positive?

          (maximum - minimum) / maximum <=
            SHORT_EDGE_SLIVER_LENGTH_RELATIVE_TOLERANCE
        end

        def parallel_segments?(segment_a, segment_b)
          vector_a = vector_between(segment_a[0], segment_a[1])
          vector_b = vector_between(segment_b[0], segment_b[1])
          length_product = vector_length(vector_a) * vector_length(vector_b)
          return false unless length_product.positive?

          cosine = vector_dot(vector_a, vector_b).abs / length_product
          threshold = Math.cos(
            SHORT_EDGE_SLIVER_PARALLEL_ANGLE_DEG * Math::PI / 180.0
          )
          cosine + 1.0e-15 >= threshold
        end

        def short_edge_cluster_targets(pairs, point_by_key)
          parent = {}
          find = nil
          find = lambda do |key|
            parent[key] ||= key
            parent[key] = find.call(parent[key]) unless parent[key] == key
            parent[key]
          end
          union = lambda do |key_a, key_b|
            root_a = find.call(key_a)
            root_b = find.call(key_b)
            parent[root_b] = root_a unless root_a == root_b
          end

          pairs.each do |key_a, key_b|
            return { ok: false, reason: :missing_source_point } unless
              point_by_key.key?(key_a) && point_by_key.key?(key_b)

            union.call(key_a, key_b)
          end

          clusters = parent.keys.group_by { |key| find.call(key) }.values
          point_targets = {}
          cluster_reports = []
          clusters.each do |members|
            diameter_mm = members.combination(2).map do |key_a, key_b|
              point_distance_mm(point_by_key[key_a], point_by_key[key_b])
            end.max || 0.0
            if diameter_mm >= SHORT_EDGE_SLIVER_MAX_CLUSTER_DIAMETER_MM
              return {
                ok: false,
                reason: :cluster_too_wide,
                diameter_mm: diameter_mm
              }
            end

            target_key = 3.times.map do |axis|
              (members.sum { |key| key[axis] }.to_f / members.length).round
            end
            if point_by_key.key?(target_key) && !members.include?(target_key)
              target_key = members.min_by do |key|
                members.sum do |other|
                  integer_dot(integer_subtract(key, other), integer_subtract(key, other))
                end
              end
            end
            target_point = point_from_grid_indices(target_key)
            displacements = members.map do |key|
              point_distance_mm(point_by_key[key], target_point)
            end

            members.each do |key|
              point_targets[key] = target_point unless key == target_key
            end
            cluster_reports << {
              members: members,
              target: target_key,
              diameter_mm: diameter_mm,
              displacements_mm: displacements
            }
          end

          { ok: true, point_targets: point_targets, clusters: cluster_reports }
        end

        def collapse_short_edge_sliver_triangles(
          triangle_records,
          plan,
          baseline_validation
        )
          base_report = plan.merge(
            removed_degenerate_triangle_count: 0,
            removed_duplicate_triangle_count: 0,
            euler_characteristic_before:
              triangle_mesh_euler_characteristic(baseline_validation),
            euler_characteristic_after:
              triangle_mesh_euler_characteristic(baseline_validation)
          )
          return [triangle_records, base_report] unless plan[:repairable]

          signatures = {}
          removed_degenerate = 0
          removed_duplicate = 0
          repaired = triangle_records.filter_map do |record|
            points = record[:points].map do |point|
              plan[:point_targets][grid_indices(point)] || point
            end
            triangle = points.map { |point| grid_indices(point) }
            if triangle.uniq.length != 3 ||
               integer_zero_vector?(integer_triangle_normal(triangle))
              removed_degenerate += 1
              next
            end

            signature = canonical_triangle_key(triangle)
            if signatures.key?(signature)
              removed_duplicate += 1
              next
            end

            signatures[signature] = true
            record.merge(points: points)
          end

          [
            repaired,
            base_report.merge(
              removed_degenerate_triangle_count: removed_degenerate,
              removed_duplicate_triangle_count: removed_duplicate
            )
          ]
        end

        def validate_short_edge_sliver_topology!(before, after, report)
          before_euler = triangle_mesh_euler_characteristic(before)
          after_euler = triangle_mesh_euler_characteristic(after)
          report[:euler_characteristic_after] = after_euler
          return unless report[:repairable]
          return if before_euler == after_euler &&
                    before[:component_count] == after[:component_count]

          raise TopologyChangedError,
                "Short-edge sliver collapse changed shell topology: " \
                "euler=#{before_euler}->#{after_euler} " \
                "components=#{before[:component_count]}->#{after[:component_count]}"
        end

        def triangle_mesh_euler_characteristic(validation)
          validation[:vertex_count].to_i -
            validation[:edge_count].to_i +
            validation[:triangle_count].to_i
        end

        def point_from_grid_indices(indices)
          @point_factory.call(
            indices[0] * @tolerance_mm / MM_PER_INCH,
            indices[1] * @tolerance_mm / MM_PER_INCH,
            indices[2] * @tolerance_mm / MM_PER_INCH
          )
        end

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

        # Captures each source Face from its B-rep boundary loops. Face#mesh is
        # only a compatibility fallback for entities without usable loops: its
        # internal diagonals are not source topology and can overlap when a long
        # n-gon boundary contains almost-collinear vertices.
        def triangle_snapshot(entities)
          entities.grep(@face_class).flat_map do |face|
            source_face_key = stable_entity_id(face)
            if face.respond_to?(:loops)
              begin
                next source_boundary_triangle_records(face, source_face_key)
              rescue Error, ArgumentError
                # Some legacy SketchUp Faces contain numerically invalid loops
                # that SketchUp can still mesh. Retain that mesh as input to the
                # later exact repair gates instead of accepting it silently.
              end
            end

            mesh = face.mesh(0)
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

        # Rebuild a Face snapshot from its boundary loops. Decisions use a stable
        # 2D projection at GRID_EPSILON_MM precision; returned records retain the
        # original SketchUp points.
        def source_boundary_triangle_records(face, source_face_key)
          source_normal = vector_components(face.normal)
          drop_axis = source_normal.each_index.max_by do |axis|
            source_normal[axis].abs
          end
          point_by_key = {}
          loops = face.loops.map do |loop|
            keys = loop.vertices.map do |vertex|
              point = vertex.position
              key = source_precision_indices(point)
              point_by_key[key] ||= point
              key
            end
            compact_integer_loop(keys)
          end
          if loops.empty? || loops.any? { |loop| loop.length < 3 }
            raise ReconstructionError,
                  "Source face boundary cannot be triangulated: face=#{source_face_key.inspect}"
          end

          outer, holes = classify_exact_patch_loops(loops, drop_axis)
          triangle_keys = triangulate_exact_polygon_with_holes(
            outer,
            holes,
            drop_axis
          )
          records = triangle_keys.each_with_index.map do |keys, polygon_index|
            points = keys.map { |key| point_by_key.fetch(key) }
            actual_normal = vector_cross(
              vector_between(points[0], points[1]),
              vector_between(points[0], points[2])
            )
            points = [points[0], points[2], points[1]] if
              vector_dot(actual_normal, source_normal).negative?
            {
              points: points,
              source_normal: source_normal,
              material: face.material,
              back_material: face.back_material,
              layer: face.layer,
              source_face_key: source_face_key,
              source_polygon_index: polygon_index,
              source_boundary_snapshot: true
            }
          end

          validate_source_boundary_retriangulation!(records, loops)
          records
        end

        def compact_integer_loop(points)
          compact = []
          points.each do |point|
            compact << point unless compact.last == point
          end
          compact.pop if compact.length > 1 && compact.first == compact.last
          compact
        end

        def validate_source_boundary_retriangulation!(records, loops)
          triangles = records.map do |record|
            record[:points].map { |point| source_precision_indices(point) }
          end
          if triangles.any? do |triangle|
               triangle.uniq.length != 3 ||
                 integer_zero_vector?(integer_triangle_normal(triangle))
             end
            raise ReconstructionError,
                  'Source boundary retriangulation created a degenerate triangle'
          end
          validate_triangle_intersections!(triangles)

          incidence = Hash.new(0)
          triangles.each do |triangle|
            3.times do |index|
              incidence[canonical_edge_key(
                triangle[index],
                triangle[(index + 1) % 3]
              )] += 1
            end
          end
          if incidence.values.any? { |count| count > 2 }
            raise TopologyChangedError,
                  'Source boundary retriangulation created an overused edge'
          end

          expected_boundary = loops.flat_map do |loop|
            loop.each_index.map do |index|
              canonical_edge_key(loop[index], loop[(index + 1) % loop.length])
            end
          end.sort
          actual_boundary = incidence.filter_map do |edge, count|
            edge if count == 1
          end.sort
          return true if actual_boundary == expected_boundary

          raise TopologyChangedError,
                'Source boundary retriangulation did not preserve the Face loops'
        end

        def source_precision_indices(point)
          [point.x, point.y, point.z].map do |coordinate|
            ((coordinate.to_f * MM_PER_INCH) / GRID_EPSILON_MM).round
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

        def conforming_triangle_snapshot(source_triangles, coordinate_space: :grid)
          unique_points = {}
          source_triangles.each do |record|
            record[:points].each do |point|
              unique_points[triangle_point_key(point, coordinate_space)] ||= point
            end
          end

          candidates = unique_points.values
          signatures = {}

          source_triangles.flat_map do |record|
            if degenerate_triangle_record?(
              record,
              coordinate_space: coordinate_space
            )
              next [record] if coordinate_space == :source

              next []
            end

            boundary = triangle_boundary_with_segment_vertices(
              record[:points],
              candidates,
              coordinate_space: coordinate_space
            )

            triangulate_convex_boundary(
              boundary,
              candidates,
              coordinate_space: coordinate_space
            ).map do |points|
              signature = triangle_signature_for_space(points, coordinate_space)
              if signatures.key?(signature)
                raise ReconstructionError,
                      "Duplicate conforming triangle detected: #{signature.inspect}"
              end

              signatures[signature] = true
              record.merge(points: points)
            end
          end
        end


        def exact_coplanar_patch_retriangulation_required?(patch)
          triangles = patch.map do |record|
            triangle = record[:points].map { |point| grid_indices(point) }
            source_normal = Array(record[:source_normal]).map(&:to_f)
            actual_normal = integer_triangle_normal(triangle)
            return true if source_normal.length == 3 &&
                           vector_dot(actual_normal, source_normal).negative?
            return true if exact_triangle_minimum_altitude_mm(triangle) < @tolerance_mm

            triangle
          end

          validate_triangle_intersections!(triangles)
          false
        rescue TopologyChangedError
          true
        end

        def exact_triangle_minimum_altitude_mm(triangle)
          normal_length = Math.sqrt(
            integer_dot(
              integer_triangle_normal(triangle),
              integer_triangle_normal(triangle)
            ).to_f
          )
          longest_edge = 3.times.map do |index|
            edge = integer_subtract(
              triangle[index],
              triangle[(index + 1) % 3]
            )
            Math.sqrt(integer_dot(edge, edge).to_f)
          end.max
          return 0.0 unless longest_edge&.positive?

          (normal_length / longest_edge) * @tolerance_mm
        end

        def exact_coplanar_triangle_patches(triangle_records)
          grouped = triangle_records.group_by do |record|
            exact_coplanar_patch_key(record)
          end
          patches = []

          grouped.each_value do |records|
            edge_owners = Hash.new { |hash, key| hash[key] = [] }
            records.each_with_index do |record, index|
              triangle = record[:points].map { |point| grid_indices(point) }
              3.times do |edge_index|
                edge = canonical_edge_key(
                  triangle[edge_index],
                  triangle[(edge_index + 1) % 3]
                )
                edge_owners[edge] << index
              end
            end

            adjacency = Array.new(records.length) { [] }
            edge_owners.each_value do |owners|
              next unless owners.length == 2

              first, second = owners
              adjacency[first] << second
              adjacency[second] << first
            end

            visited = Array.new(records.length, false)
            records.each_index do |seed|
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
              patches << component
            end
          end

          patches
        end

        def exact_coplanar_patch_key(record)
          triangle = record[:points].map { |point| grid_indices(point) }
          plane_key = exact_integer_plane_key(triangle)
          normal = plane_key.first(3)
          source_normal = Array(record[:source_normal]).map(&:to_f)
          orientation = if source_normal.length == 3 &&
                           vector_dot(normal, source_normal).negative?
                          -1
                        else
                          1
                        end

          [
            plane_key,
            orientation,
            metadata_identity(record[:material]),
            metadata_identity(record[:back_material]),
            metadata_identity(record[:layer])
          ]
        end

        def metadata_identity(value)
          return nil if value.nil?
          return [:persistent_id, value.persistent_id] if value.respond_to?(:persistent_id)

          [:object_id, value.object_id]
        rescue StandardError
          [:object_id, value.object_id]
        end

        def exact_integer_plane_key(triangle)
          normal = integer_triangle_normal(triangle)
          if integer_zero_vector?(normal)
            raise ReconstructionError,
                  "Cannot form an exact plane from a zero-area triangle: #{triangle.inspect}"
          end

          divisor = normal.map(&:abs).reject(&:zero?).reduce { |gcd, value| gcd.gcd(value) }
          primitive = normal.map { |value| value / divisor }
          first_nonzero = primitive.find { |value| !value.zero? }
          primitive = primitive.map(&:-@) if first_nonzero.negative?
          primitive + [integer_dot(primitive, triangle[0])]
        end

        def retriangulate_exact_coplanar_patch(patch)
          point_by_key = {}
          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          patch.each_with_index do |record, index|
            triangle = record[:points].map do |point|
              key = grid_indices(point)
              point_by_key[key] ||= point
              key
            end
            3.times do |edge_index|
              edge = canonical_edge_key(
                triangle[edge_index],
                triangle[(edge_index + 1) % 3]
              )
              edge_owners[edge] << index
            end
          end

          overused = edge_owners.select { |_edge, owners| owners.length > 2 }
          unless overused.empty?
            raise TopologyChangedError,
                  "Exact coplanar patch has overused edges: #{overused.first(10).inspect}"
          end

          boundary_edges = edge_owners.filter_map do |edge, owners|
            edge if owners.length == 1
          end
          if boundary_edges.empty?
            raise TopologyChangedError, 'Exact coplanar patch has no preserved boundary'
          end

          loops = exact_boundary_loops(boundary_edges)
          plane_key = exact_integer_plane_key(
            patch.first[:points].map { |point| grid_indices(point) }
          )
          drop_axis = plane_key.first(3).each_index.max_by do |axis|
            plane_key[axis].abs
          end
          outer, holes = classify_exact_patch_loops(loops, drop_axis)
          expected_area2 = integer_polygon_area2(
            outer.map { |point| integer_project_2d(point, drop_axis) }
          ).abs - holes.sum do |hole|
            integer_polygon_area2(
              hole.map { |point| integer_project_2d(point, drop_axis) }
            ).abs
          end
          triangle_keys = triangulate_exact_polygon_with_holes(
            outer,
            holes,
            drop_axis
          )

          template = patch.first
          replacements = triangle_keys.each_with_index.map do |keys, index|
            points = keys.map { |key| point_by_key.fetch(key) }
            points = orient_patch_triangle(points, template[:source_normal])
            template.merge(
              points: points,
              source_polygon_index: index
            )
          end

          validate_exact_patch_replacement!(
            replacements,
            boundary_edges,
            loops.length,
            drop_axis,
            expected_area2
          )

          [
            replacements,
            {
              boundary_loops: loops.length,
              holes: holes.length
            }
          ]
        end

        def exact_boundary_loops(boundary_edges)
          adjacency = Hash.new { |hash, key| hash[key] = [] }
          boundary_edges.each do |point_a, point_b|
            adjacency[point_a] << point_b
            adjacency[point_b] << point_a
          end
          bad_vertices = adjacency.select { |_point, neighbors| neighbors.uniq.length != 2 }
          unless bad_vertices.empty?
            raise TopologyChangedError,
                  "Exact coplanar patch boundary is branched: " \
                  "#{bad_vertices.first(10).inspect}"
          end

          unused = boundary_edges.each_with_object({}) do |edge, result|
            result[canonical_edge_key(edge[0], edge[1])] = true
          end
          loops = []
          until unused.empty?
            seed = unused.keys.first
            start_point, current = seed
            previous = start_point
            loop_points = [start_point]
            unused.delete(seed)

            boundary_edges.length.times do
              loop_points << current
              break if current == start_point

              following = adjacency.fetch(current).find do |candidate|
                candidate != previous &&
                  unused.key?(canonical_edge_key(current, candidate))
              end
              following ||= adjacency.fetch(current).find do |candidate|
                unused.key?(canonical_edge_key(current, candidate))
              end
              unless following
                raise TopologyChangedError,
                      "Exact coplanar patch boundary does not form a closed loop at " \
                      "#{current.inspect}"
              end

              unused.delete(canonical_edge_key(current, following))
              previous, current = current, following
            end

            unless loop_points.last == start_point
              raise TopologyChangedError, 'Exact coplanar patch boundary walk did not close'
            end
            loop_points.pop
            if loop_points.length < 3
              raise TopologyChangedError,
                    "Exact coplanar patch has a boundary loop with fewer than three vertices"
            end
            loops << loop_points
          end

          loops
        end

        def classify_exact_patch_loops(loops, drop_axis)
          projected = loops.map do |loop|
            [loop, loop.map { |point| integer_project_2d(point, drop_axis) }]
          end
          projected.each do |_loop, polygon|
            if integer_polygon_area2(polygon).zero?
              raise TopologyChangedError, 'Exact coplanar patch has a zero-area boundary loop'
            end
            unless simple_integer_polygon_2d?(polygon)
              raise TopologyChangedError,
                    'Exact coplanar patch boundary self-intersects after normalization'
            end
          end

          outer_entry = projected.max_by do |_loop, polygon|
            integer_polygon_area2(polygon).abs
          end
          outer_loop, outer_polygon = outer_entry
          holes = projected.reject { |entry| entry.equal?(outer_entry) }
          holes.each do |_loop, polygon|
            unless integer_point_in_polygon_2d?(polygon.first, outer_polygon)
              raise TopologyChangedError,
                    'Exact coplanar patch contains more than one exterior boundary'
            end
          end

          outer_loop = outer_loop.reverse if integer_polygon_area2(outer_polygon).negative?
          oriented_holes = holes.map do |loop, polygon|
            integer_polygon_area2(polygon).positive? ? loop.reverse : loop
          end
          [outer_loop, oriented_holes]
        end

        def triangulate_exact_polygon_with_holes(outer, holes, drop_axis)
          polygon = outer.dup
          original_outer_2d = outer.map { |point| integer_project_2d(point, drop_axis) }
          original_holes_2d = holes.map do |hole|
            hole.map { |point| integer_project_2d(point, drop_axis) }
          end

          holes.sort_by do |hole|
            hole.map { |point| integer_project_2d(point, drop_axis)[0] }.max
          end.reverse_each do |hole|
            polygon = bridge_exact_hole(
              polygon,
              hole,
              original_outer_2d,
              original_holes_2d,
              drop_axis
            )
          end

          triangles = triangulate_exact_weak_polygon(polygon, drop_axis)
          boundary_edges = (outer.each_index.map do |index|
            canonical_edge_key(outer[index], outer[(index + 1) % outer.length])
          end + holes.flat_map do |hole|
            hole.each_index.map do |index|
              canonical_edge_key(hole[index], hole[(index + 1) % hole.length])
            end
          end).to_h { |edge| [edge, true] }

          optimize_exact_patch_triangulation(
            triangles,
            boundary_edges,
            drop_axis
          )
        end

        def bridge_exact_hole(polygon, hole, outer_2d, holes_2d, drop_axis)
          hole_index = hole.each_index.max_by do |index|
            point = integer_project_2d(hole[index], drop_axis)
            [point[0], -point[1]]
          end
          hole_point = hole[hole_index]
          hole_point_2d = integer_project_2d(hole_point, drop_axis)
          polygon_2d = polygon.map { |point| integer_project_2d(point, drop_axis) }
          all_loops = [polygon_2d] + holes_2d

          candidates = polygon.each_index.filter_map do |polygon_index|
            polygon_point = polygon[polygon_index]
            polygon_point_2d = polygon_2d[polygon_index]
            next if polygon_point_2d == hole_point_2d
            next unless exact_bridge_visible?(
              hole_point_2d,
              polygon_point_2d,
              all_loops,
              outer_2d,
              holes_2d
            )

            delta = integer_subtract_2d(polygon_point_2d, hole_point_2d)
            [integer_dot_2d(delta, delta), polygon_index]
          end
          if candidates.empty?
            raise ReconstructionError,
                  'Could not connect an exact coplanar patch hole to its exterior boundary'
          end

          polygon_index = candidates.min_by(&:first).last
          polygon_point = polygon[polygon_index]
          rotated_hole = hole[hole_index..] + hole[0...hole_index]
          polygon[0..polygon_index] +
            rotated_hole +
            [hole_point, polygon_point] +
            Array(polygon[(polygon_index + 1)..])
        end

        def exact_bridge_visible?(point_a, point_b, loops, outer, holes)
          loops.each do |loop|
            loop.each_index do |index|
              edge_a = loop[index]
              edge_b = loop[(index + 1) % loop.length]
              next if edge_a == point_a || edge_b == point_a ||
                      edge_a == point_b || edge_b == point_b
              return false if integer_segments_intersect_2d?(
                point_a,
                point_b,
                edge_a,
                edge_b
              )
            end
            loop.each do |point|
              next if point == point_a || point == point_b
              return false if integer_point_on_segment_2d?(point, point_a, point_b)
            end
          end

          midpoint = [
            Rational(point_a[0] + point_b[0], 2),
            Rational(point_a[1] + point_b[1], 2)
          ]
          return false unless integer_point_in_polygon_2d?(midpoint, outer)
          return false if holes.any? do |hole|
            integer_point_in_polygon_2d?(midpoint, hole)
          end

          true
        end

        def triangulate_exact_weak_polygon(points, drop_axis)
          remaining = points.dup
          triangles = []
          limit = remaining.length * remaining.length * 2
          attempts = 0

          while remaining.length > 3
            ear_indices = remaining.each_index.select do |index|
              exact_polygon_ear?(remaining, index, drop_axis)
            end
            ear_index = ear_indices.max_by do |index|
              exact_polygon_ear_quality(remaining, index, drop_axis)
            end
            unless ear_index
              raise ReconstructionError,
                    "Could not triangulate exact coplanar patch boundary: " \
                    "#{remaining.inspect}"
            end

            previous_point = remaining[(ear_index - 1) % remaining.length]
            current_point = remaining[ear_index]
            following_point = remaining[(ear_index + 1) % remaining.length]
            triangles << [previous_point, current_point, following_point]
            remaining.delete_at(ear_index)
            attempts += 1
            if attempts > limit
              raise ReconstructionError,
                    'Exact coplanar patch triangulation exceeded its iteration limit'
            end
          end

          final = remaining.map { |point| integer_project_2d(point, drop_axis) }
          if final.uniq.length != 3 || integer_orientation_2d(*final).zero?
            raise ReconstructionError,
                  "Exact coplanar patch ended with a zero-area triangle: #{remaining.inspect}"
          end
          triangles << remaining
          triangles
        end

        # Among all topologically valid ears, prefer the one with the greatest
        # squared minimum-altitude proxy (area^2 / longest_edge^2). This keeps a
        # short preserved boundary segment from being paired with a nearly
        # collinear third point merely because that ear appeared first.
        def exact_polygon_ear_quality(polygon, index, drop_axis)
          points = [
            polygon[(index - 1) % polygon.length],
            polygon[index],
            polygon[(index + 1) % polygon.length]
          ].map { |point| integer_project_2d(point, drop_axis) }
          area2 = integer_orientation_2d(*points).abs
          longest_edge_squared = 3.times.map do |edge_index|
            vector = integer_subtract_2d(
              points[edge_index],
              points[(edge_index + 1) % 3]
            )
            integer_dot_2d(vector, vector)
          end.max

          Rational(area2 * area2, longest_edge_squared)
        end

        # Improves the ear-clipped mesh with exact, constraint-preserving
        # Lawson flips. Only an interior diagonal shared by two triangles may
        # change. A flip is accepted when the two triangles still cover the
        # identical convex quadrilateral and their worst minimum-altitude
        # proxy strictly improves. All decisions use integer grid coordinates.
        def optimize_exact_patch_triangulation(triangles, constraints, drop_axis)
          optimized = triangles.map(&:dup)
          iteration_limit = [optimized.length * optimized.length * 2, 1].max
          iterations = 0

          loop do
            edge_owners = Hash.new { |hash, key| hash[key] = [] }
            optimized.each_with_index do |triangle, triangle_index|
              3.times do |edge_index|
                edge = canonical_edge_key(
                  triangle[edge_index],
                  triangle[(edge_index + 1) % 3]
                )
                edge_owners[edge] << triangle_index
              end
            end

            candidates = edge_owners.filter_map do |edge, owners|
              next unless owners.length == 2
              next if constraints.key?(edge)

              first_index, second_index = owners
              first = optimized[first_index]
              second = optimized[second_index]
              opposite_a = (first - edge).first
              opposite_b = (second - edge).first
              next unless opposite_a && opposite_b && opposite_a != opposite_b

              alternate_edge = canonical_edge_key(opposite_a, opposite_b)
              next if edge_owners.key?(alternate_edge)

              replacement = exact_edge_flip_replacement(
                edge,
                opposite_a,
                opposite_b,
                drop_axis
              )
              next unless replacement

              current_quality = [
                exact_integer_triangle_quality(first),
                exact_integer_triangle_quality(second)
              ].min
              replacement_quality = replacement.map do |triangle|
                exact_integer_triangle_quality(triangle)
              end.min
              next unless replacement_quality > current_quality

              [
                replacement_quality - current_quality,
                replacement_quality,
                edge,
                first_index,
                second_index,
                replacement
              ]
            end
            break if candidates.empty?

            candidate = candidates.max_by do |entry|
              [entry[0], entry[1], entry[2]]
            end
            first_index = candidate[3]
            second_index = candidate[4]
            replacement = candidate[5]
            optimized[first_index] = replacement[0]
            optimized[second_index] = replacement[1]

            iterations += 1
            if iterations > iteration_limit
              raise ReconstructionError,
                    'Exact coplanar patch edge optimization exceeded its iteration limit'
            end
          end

          optimized
        end

        def exact_edge_flip_replacement(edge, opposite_a, opposite_b, drop_axis)
          edge_a, edge_b = edge
          projected = [edge_a, edge_b, opposite_a, opposite_b].to_h do |point|
            [point, integer_project_2d(point, drop_axis)]
          end

          side_a = integer_orientation_2d(
            projected[edge_a],
            projected[edge_b],
            projected[opposite_a]
          )
          side_b = integer_orientation_2d(
            projected[edge_a],
            projected[edge_b],
            projected[opposite_b]
          )
          return nil if side_a.zero? || side_b.zero?
          return nil if side_a.positive? == side_b.positive?

          alternate_side_a = integer_orientation_2d(
            projected[opposite_a],
            projected[opposite_b],
            projected[edge_a]
          )
          alternate_side_b = integer_orientation_2d(
            projected[opposite_a],
            projected[opposite_b],
            projected[edge_b]
          )
          return nil if alternate_side_a.zero? || alternate_side_b.zero?
          return nil if alternate_side_a.positive? == alternate_side_b.positive?

          replacements = [
            [opposite_a, opposite_b, edge_a],
            [opposite_b, opposite_a, edge_b]
          ].map do |triangle|
            orientation = integer_orientation_2d(
              *triangle.map { |point| projected[point] }
            )
            return nil if orientation.zero?

            orientation.positive? ? triangle : [triangle[0], triangle[2], triangle[1]]
          end

          original_area2 = [opposite_a, opposite_b].sum do |opposite|
            integer_orientation_2d(
              projected[edge_a],
              projected[edge_b],
              projected[opposite]
            ).abs
          end
          replacement_area2 = replacements.sum do |triangle|
            integer_orientation_2d(
              *triangle.map { |point| projected[point] }
            ).abs
          end
          return nil unless replacement_area2 == original_area2

          replacements
        end

        def exact_integer_triangle_quality(triangle)
          normal = integer_triangle_normal(triangle)
          normal_squared = integer_dot(normal, normal)
          longest_edge_squared = 3.times.map do |edge_index|
            vector = integer_subtract(
              triangle[edge_index],
              triangle[(edge_index + 1) % 3]
            )
            integer_dot(vector, vector)
          end.max

          Rational(normal_squared, longest_edge_squared)
        end

        def exact_polygon_ear?(polygon, index, drop_axis)
          previous_index = (index - 1) % polygon.length
          following_index = (index + 1) % polygon.length
          point_a = integer_project_2d(polygon[previous_index], drop_axis)
          point_b = integer_project_2d(polygon[index], drop_axis)
          point_c = integer_project_2d(polygon[following_index], drop_axis)
          return false unless integer_orientation_2d(point_a, point_b, point_c).positive?

          polygon.each_index do |candidate_index|
            next if [previous_index, index, following_index].include?(candidate_index)

            candidate = integer_project_2d(polygon[candidate_index], drop_axis)
            next if candidate == point_a || candidate == point_b || candidate == point_c
            return false if integer_point_in_triangle_2d?(
              candidate,
              point_a,
              point_b,
              point_c
            )
          end

          polygon.each_index do |edge_index|
            edge_following = (edge_index + 1) % polygon.length
            next if [previous_index, index].include?(edge_index)
            next if [previous_index, following_index].include?(edge_following)

            edge_a = integer_project_2d(polygon[edge_index], drop_axis)
            edge_b = integer_project_2d(polygon[edge_following], drop_axis)
            next if edge_a == point_a || edge_b == point_a ||
                    edge_a == point_c || edge_b == point_c
            return false if integer_segments_intersect_2d?(
              point_a,
              point_c,
              edge_a,
              edge_b
            )
          end

          true
        end

        def validate_exact_patch_replacement!(
          records,
          boundary_edges,
          loop_count,
          drop_axis = nil,
          expected_area2 = nil
        )
          if records.empty?
            raise ReconstructionError, 'Exact coplanar patch triangulation returned no triangles'
          end

          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          triangles = records.map.with_index do |record, index|
            triangle = record[:points].map { |point| grid_indices(point) }
            if triangle.uniq.length != 3 || integer_zero_vector?(integer_triangle_normal(triangle))
              raise ReconstructionError,
                    "Exact coplanar patch produced a zero-area triangle: #{triangle.inspect}"
            end
            3.times do |edge_index|
              edge = canonical_edge_key(
                triangle[edge_index],
                triangle[(edge_index + 1) % 3]
              )
              edge_owners[edge] << index
            end
            triangle
          end

          replacement_boundary = edge_owners.filter_map do |edge, owners|
            edge if owners.length == 1
          end.sort
          expected_boundary = boundary_edges.map do |edge|
            canonical_edge_key(edge[0], edge[1])
          end.sort
          unless replacement_boundary == expected_boundary
            missing = expected_boundary - replacement_boundary
            added = replacement_boundary - expected_boundary
            raise TopologyChangedError,
                  "Exact coplanar retriangulation changed its constraints: " \
                  "missing=#{missing.first(10).inspect} added=#{added.first(10).inspect}"
          end

          invalid_edges = edge_owners.select do |_edge, owners|
            owners.length != 1 && owners.length != 2
          end
          unless invalid_edges.empty?
            raise TopologyChangedError,
                  "Exact coplanar retriangulation has invalid edge incidence: " \
                  "#{invalid_edges.first(10).inspect}"
          end

          vertex_count = triangles.flatten(1).uniq.length
          euler = vertex_count - edge_owners.length + triangles.length
          expected_euler = 2 - loop_count
          unless euler == expected_euler
            raise TopologyChangedError,
                  "Exact coplanar retriangulation changed patch topology: " \
                  "euler=#{euler} expected=#{expected_euler}"
          end


          if drop_axis && expected_area2
            actual_area2 = triangles.sum do |triangle|
              integer_orientation_2d(
                *triangle.map { |point| integer_project_2d(point, drop_axis) }
              ).abs
            end
            unless actual_area2 == expected_area2
              raise TopologyChangedError,
                    "Exact coplanar retriangulation changed patch area: " \
                    "area2=#{expected_area2}->#{actual_area2}"
            end
          end

          validate_triangle_intersections!(triangles)
        end

        def orient_patch_triangle(points, source_normal)
          keys = points.map { |point| grid_indices(point) }
          normal = integer_triangle_normal(keys)
          expected = Array(source_normal).map(&:to_f)
          return points unless expected.length == 3
          return points unless vector_dot(normal, expected).negative?

          [points[0], points[2], points[1]]
        end

        def integer_project_2d(point, drop_axis)
          point.each_with_index.filter_map do |coordinate, axis|
            coordinate unless axis == drop_axis
          end
        end

        def integer_polygon_area2(polygon)
          polygon.each_index.sum do |index|
            point_a = polygon[index]
            point_b = polygon[(index + 1) % polygon.length]
            (point_a[0] * point_b[1]) - (point_b[0] * point_a[1])
          end
        end

        def integer_orientation_2d(point_a, point_b, point_c)
          ((point_b[0] - point_a[0]) * (point_c[1] - point_a[1])) -
            ((point_b[1] - point_a[1]) * (point_c[0] - point_a[0]))
        end

        def integer_subtract_2d(point_a, point_b)
          [point_a[0] - point_b[0], point_a[1] - point_b[1]]
        end

        def integer_dot_2d(vector_a, vector_b)
          (vector_a[0] * vector_b[0]) + (vector_a[1] * vector_b[1])
        end

        def integer_point_on_segment_2d?(point, segment_a, segment_b)
          return false unless integer_orientation_2d(segment_a, segment_b, point).zero?

          point[0] >= [segment_a[0], segment_b[0]].min &&
            point[0] <= [segment_a[0], segment_b[0]].max &&
            point[1] >= [segment_a[1], segment_b[1]].min &&
            point[1] <= [segment_a[1], segment_b[1]].max
        end

        def integer_segments_intersect_2d?(point_a, point_b, point_c, point_d)
          orientations = [
            integer_orientation_2d(point_a, point_b, point_c),
            integer_orientation_2d(point_a, point_b, point_d),
            integer_orientation_2d(point_c, point_d, point_a),
            integer_orientation_2d(point_c, point_d, point_b)
          ]
          return true if orientations[0].zero? &&
                         integer_point_on_segment_2d?(point_c, point_a, point_b)
          return true if orientations[1].zero? &&
                         integer_point_on_segment_2d?(point_d, point_a, point_b)
          return true if orientations[2].zero? &&
                         integer_point_on_segment_2d?(point_a, point_c, point_d)
          return true if orientations[3].zero? &&
                         integer_point_on_segment_2d?(point_b, point_c, point_d)

          (orientations[0].positive? != orientations[1].positive?) &&
            (orientations[2].positive? != orientations[3].positive?)
        end

        def simple_integer_polygon_2d?(polygon)
          polygon.each_index do |first_index|
            first_following = (first_index + 1) % polygon.length
            polygon.each_index do |second_index|
              second_following = (second_index + 1) % polygon.length
              next if first_index == second_index
              next if first_following == second_index || second_following == first_index

              return false if integer_segments_intersect_2d?(
                polygon[first_index],
                polygon[first_following],
                polygon[second_index],
                polygon[second_following]
              )
            end
          end
          true
        end

        def integer_point_in_polygon_2d?(point, polygon)
          return true if polygon.each_index.any? do |index|
            integer_point_on_segment_2d?(
              point,
              polygon[index],
              polygon[(index + 1) % polygon.length]
            )
          end

          inside = false
          previous = polygon.last
          polygon.each do |current|
            crosses = (current[1] > point[1]) != (previous[1] > point[1])
            if crosses
              intersection_x = Rational(
                (previous[0] - current[0]) * (point[1] - current[1]),
                previous[1] - current[1]
              ) + current[0]
              inside = !inside if point[0] < intersection_x
            end
            previous = current
          end
          inside
        end

        def integer_point_in_triangle_2d?(point, point_a, point_b, point_c)
          orientations = [
            integer_orientation_2d(point_a, point_b, point),
            integer_orientation_2d(point_b, point_c, point),
            integer_orientation_2d(point_c, point_a, point)
          ]
          orientations.all? { |value| value >= 0 } ||
            orientations.all? { |value| value <= 0 }
        end

        # Validates the snapped surface as an exact integer-grid triangle
        # complex before any SketchUp entities are erased. Integer arithmetic
        # avoids introducing a second geometric tolerance into normalization.
        def validate_normalized_triangle_shapes!(triangle_records)
          triangle_records.each_with_index do |record, index|
            triangle = record[:points].map { |point| grid_indices(point) }
            next if triangle.uniq.length == 3 &&
                    !integer_zero_vector?(integer_triangle_normal(triangle))

            raise ReconstructionError,
                  "Grid projection collapses source triangle #{index}: #{triangle.inspect}"
          end
        end

        def validate_normalized_triangle_mesh!(triangle_records)
          validation = validate_normalized_triangle_topology!(triangle_records)
          triangles = triangle_records.map do |record|
            record[:points].map { |point| grid_indices(point) }
          end
          tested_pairs = validate_triangle_intersections!(triangles)

          validation.merge(tested_triangle_pairs: tested_pairs)
        end

        # Validates only the combinatorial closed-manifold invariants. Geometry
        # intersections are deliberately checked after exact coplanar patches
        # have been reconstructed from their preserved boundary constraints.
        def validate_normalized_triangle_topology!(triangle_records)
          triangles = triangle_records.map do |record|
            record[:points].map { |point| grid_indices(point) }
          end
          raise ReconstructionError, 'Normalized triangle mesh is empty' if triangles.empty?

          signatures = {}
          edge_incidence = Hash.new { |hash, key| hash[key] = [] }
          vertices = {}

          triangles.each_with_index do |triangle, triangle_index|
            if triangle.uniq.length != 3 || integer_zero_vector?(integer_triangle_normal(triangle))
              raise ReconstructionError,
                    "Normalized triangle #{triangle_index} is degenerate: #{triangle.inspect}"
            end

            signature = canonical_triangle_key(triangle)
            if signatures.key?(signature)
              raise ReconstructionError,
                    "Duplicate normalized triangle #{triangle_index}: #{triangle.inspect}"
            end
            signatures[signature] = triangle_index

            triangle.each { |vertex| vertices[vertex] = true }
            3.times do |edge_index|
              edge = canonical_edge_key(
                triangle[edge_index],
                triangle[(edge_index + 1) % 3]
              )
              edge_incidence[edge] << triangle_index
            end
          end

          bad_edges = edge_incidence.select { |_edge, owners| owners.length != 2 }
          unless bad_edges.empty?
            sample = bad_edges.first(10).map do |edge, owners|
              { edge: edge, incidence: owners.length, triangles: owners }
            end
            raise TopologyChangedError,
                  "Normalized mesh is not a closed 2-manifold; " \
                  "bad_edges=#{bad_edges.length} sample=#{sample.inspect}"
          end

          adjacency = Array.new(triangles.length) { [] }
          edge_incidence.each_value do |owners|
            first, second = owners
            adjacency[first] << second
            adjacency[second] << first
          end
          component_count = graph_component_count(adjacency)
          unless component_count == 1
            raise TopologyChangedError,
                  "Normalized mesh has #{component_count} disconnected shell components"
          end

          {
            vertex_count: vertices.length,
            edge_count: edge_incidence.length,
            triangle_count: triangles.length,
            component_count: component_count,
            tested_triangle_pairs: 0
          }
        end

        def verify_triangle_rebuild!(expected_records, actual_records)
          expected = expected_records.map do |record|
            canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
          end.sort
          actual = actual_records.map do |record|
            canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
          end.sort
          return if expected == actual

          missing = expected - actual
          added = actual - expected
          raise ReconstructionError,
                "SketchUp changed the validated triangle complex during rebuild: " \
                "missing=#{missing.first(10).inspect} added=#{added.first(10).inspect}"
        end

        def graph_component_count(adjacency)
          visited = Array.new(adjacency.length, false)
          components = 0

          adjacency.each_index do |seed|
            next if visited[seed]

            components += 1
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

          components
        end

        def validate_triangle_intersections!(triangles)
          tested_pairs = 0

          triangles.each_with_index do |triangle_a, index_a|
            ((index_a + 1)...triangles.length).each do |index_b|
              triangle_b = triangles[index_b]
              next unless integer_aabbs_overlap?(triangle_a, triangle_b)

              tested_pairs += 1
              next if exact_triangle_intersection_allowed?(triangle_a, triangle_b)

              raise TopologyChangedError,
                    "Normalized triangles intersect outside their shared simplex: " \
                    "triangles=#{[index_a, index_b].inspect} " \
                    "a=#{triangle_a.inspect} b=#{triangle_b.inspect}"
            end
          end

          tested_pairs
        end

        def exact_triangle_intersection_allowed?(triangle_a, triangle_b)
          shared = triangle_a & triangle_b
          return false if shared.length == 3

          normal_a = integer_triangle_normal(triangle_a)
          normal_b = integer_triangle_normal(triangle_b)
          line_direction = integer_cross(normal_a, normal_b)

          if integer_zero_vector?(line_direction)
            return true unless integer_dot(
              normal_a,
              integer_subtract(triangle_b[0], triangle_a[0])
            ).zero?

            coplanar_triangle_intersection_allowed?(triangle_a, triangle_b, shared)
          else
            noncoplanar_triangle_intersection_allowed?(
              triangle_a,
              triangle_b,
              shared,
              normal_a,
              normal_b,
              line_direction
            )
          end
        end

        def noncoplanar_triangle_intersection_allowed?(
          triangle_a,
          triangle_b,
          shared,
          normal_a,
          normal_b,
          line_direction
        )
          interval_a = triangle_plane_parameter_interval(
            triangle_a,
            triangle_b[0],
            normal_b,
            line_direction
          )
          interval_b = triangle_plane_parameter_interval(
            triangle_b,
            triangle_a[0],
            normal_a,
            line_direction
          )
          return true unless interval_a && interval_b

          overlap_min = [interval_a[0], interval_b[0]].max
          overlap_max = [interval_a[1], interval_b[1]].min
          return true if overlap_min > overlap_max

          expected = shared.map { |point| integer_dot(line_direction, point) }.minmax
          return false if expected.nil?

          overlap_min == expected[0] && overlap_max == expected[1]
        end

        def triangle_plane_parameter_interval(triangle, plane_point, plane_normal, direction)
          signs = triangle.map do |point|
            integer_dot(plane_normal, integer_subtract(point, plane_point))
          end
          return nil if signs.all?(&:positive?) || signs.all?(&:negative?)

          parameters = []
          3.times do |index|
            point_a = triangle[index]
            point_b = triangle[(index + 1) % 3]
            sign_a = signs[index]
            sign_b = signs[(index + 1) % 3]

            parameters << Rational(integer_dot(direction, point_a), 1) if sign_a.zero?
            next unless (sign_a.positive? && sign_b.negative?) ||
                        (sign_a.negative? && sign_b.positive?)

            parameter = Rational(sign_a, sign_a - sign_b)
            value_a = integer_dot(direction, point_a)
            value_b = integer_dot(direction, point_b)
            parameters << (value_a + (parameter * (value_b - value_a)))
          end

          parameters.uniq.minmax unless parameters.empty?
        end

        def coplanar_triangle_intersection_allowed?(triangle_a, triangle_b, shared)
          normal = integer_triangle_normal(triangle_a)
          drop_axis = normal.each_index.max_by { |index| normal[index].abs }
          polygon_a = triangle_a.map { |point| project_integer_point(point, drop_axis) }
          polygon_b = triangle_b.map { |point| project_integer_point(point, drop_axis) }
          intersection = convex_polygon_intersection(polygon_a, polygon_b)
          intersection = unique_rational_points(intersection)

          return intersection.empty? if shared.empty?

          shared_projected = shared.map do |point|
            project_integer_point(point, drop_axis).map { |value| Rational(value, 1) }
          end
          if shared.length == 1
            return intersection.all? { |point| point == shared_projected[0] }
          end

          segment_start, segment_end = shared_projected
          intersection.all? do |point|
            rational_point_on_segment?(point, segment_start, segment_end)
          end && intersection.include?(segment_start) && intersection.include?(segment_end)
        end

        def convex_polygon_intersection(subject, clip)
          output = subject.map { |point| point.map { |value| Rational(value, 1) } }
          clip_points = clip.map { |point| point.map { |value| Rational(value, 1) } }
          orientation = rational_polygon_area_twice(clip_points) <=> 0
          raise ReconstructionError, 'Degenerate coplanar clipping triangle' if orientation.zero?

          clip_points.each_index do |index|
            clip_start = clip_points[index]
            clip_end = clip_points[(index + 1) % clip_points.length]
            input = output
            output = []
            break if input.empty?

            previous = input.last
            previous_value = oriented_line_value(
              clip_start,
              clip_end,
              previous,
              orientation
            )
            input.each do |current|
              current_value = oriented_line_value(
                clip_start,
                clip_end,
                current,
                orientation
              )
              previous_inside = previous_value >= 0
              current_inside = current_value >= 0

              if current_inside
                if !previous_inside
                  output << rational_line_crossing(
                    previous,
                    current,
                    previous_value,
                    current_value
                  )
                end
                output << current
              elsif previous_inside
                output << rational_line_crossing(
                  previous,
                  current,
                  previous_value,
                  current_value
                )
              end

              previous = current
              previous_value = current_value
            end
            output = remove_consecutive_rational_duplicates(output)
          end

          output
        end

        def rational_line_crossing(point_a, point_b, value_a, value_b)
          parameter = Rational(value_a, value_a - value_b)
          [
            point_a[0] + (parameter * (point_b[0] - point_a[0])),
            point_a[1] + (parameter * (point_b[1] - point_a[1]))
          ]
        end

        def oriented_line_value(line_start, line_end, point, orientation)
          orientation * rational_cross_2d(
            rational_subtract_2d(line_end, line_start),
            rational_subtract_2d(point, line_start)
          )
        end

        def rational_polygon_area_twice(points)
          points.each_index.sum do |index|
            current = points[index]
            following = points[(index + 1) % points.length]
            (current[0] * following[1]) - (current[1] * following[0])
          end
        end

        def rational_point_on_segment?(point, start_point, end_point)
          direction = rational_subtract_2d(end_point, start_point)
          offset = rational_subtract_2d(point, start_point)
          return false unless rational_cross_2d(direction, offset).zero?

          point[0] >= [start_point[0], end_point[0]].min &&
            point[0] <= [start_point[0], end_point[0]].max &&
            point[1] >= [start_point[1], end_point[1]].min &&
            point[1] <= [start_point[1], end_point[1]].max
        end

        def remove_consecutive_rational_duplicates(points)
          compact = []
          points.each { |point| compact << point if compact.empty? || compact.last != point }
          compact.pop if compact.length > 1 && compact.first == compact.last
          compact
        end

        def unique_rational_points(points)
          points.each_with_object([]) do |point, unique|
            unique << point unless unique.include?(point)
          end
        end

        def rational_subtract_2d(point_a, point_b)
          [point_a[0] - point_b[0], point_a[1] - point_b[1]]
        end

        def rational_cross_2d(vector_a, vector_b)
          (vector_a[0] * vector_b[1]) - (vector_a[1] * vector_b[0])
        end

        def project_integer_point(point, drop_axis)
          point.each_with_index.filter_map { |value, index| value unless index == drop_axis }
        end

        def integer_aabbs_overlap?(triangle_a, triangle_b)
          3.times.all? do |axis|
            range_a = triangle_a.map { |point| point[axis] }.minmax
            range_b = triangle_b.map { |point| point[axis] }.minmax
            range_a[0] <= range_b[1] && range_b[0] <= range_a[1]
          end
        end

        def canonical_triangle_key(triangle)
          triangle.sort
        end

        def canonical_edge_key(point_a, point_b)
          (point_a <=> point_b) <= 0 ? [point_a, point_b] : [point_b, point_a]
        end

        def integer_triangle_normal(triangle)
          integer_cross(
            integer_subtract(triangle[1], triangle[0]),
            integer_subtract(triangle[2], triangle[0])
          )
        end

        def integer_subtract(vector_a, vector_b)
          [
            vector_a[0] - vector_b[0],
            vector_a[1] - vector_b[1],
            vector_a[2] - vector_b[2]
          ]
        end

        def integer_dot(vector_a, vector_b)
          (vector_a[0] * vector_b[0]) +
            (vector_a[1] * vector_b[1]) +
            (vector_a[2] * vector_b[2])
        end

        def integer_cross(vector_a, vector_b)
          [
            (vector_a[1] * vector_b[2]) - (vector_a[2] * vector_b[1]),
            (vector_a[2] * vector_b[0]) - (vector_a[0] * vector_b[2]),
            (vector_a[0] * vector_b[1]) - (vector_a[1] * vector_b[0])
          ]
        end

        def integer_zero_vector?(vector)
          vector.all?(&:zero?)
        end

        def triangle_signature(points)
          points.map { |point| grid_indices(point) }.sort
        end

        def triangle_boundary_with_segment_vertices(
          points,
          candidates,
          coordinate_space: :grid
        )
          boundary = []

          3.times do |index|
            start_point = points[index]
            end_point = points[(index + 1) % 3]
            boundary << start_point

            inserted = candidates.filter_map do |candidate|
              candidate_key = triangle_point_key(candidate, coordinate_space)
              next if candidate_key == triangle_point_key(start_point, coordinate_space)
              next if candidate_key == triangle_point_key(end_point, coordinate_space)

              parameter = point_on_segment_parameter(
                candidate,
                start_point,
                end_point,
                GRID_EPSILON_MM
              )
              [parameter, candidate] if parameter
            end

            boundary.concat(inserted.sort_by(&:first).map(&:last))
          end

          remove_consecutive_duplicate_points(boundary)
        end

        # The boundary is an original triangle with optional collinear points
        # inserted on its edges, so it remains convex.
        def triangulate_convex_boundary(
          points,
          candidates = points,
          coordinate_space: :grid
        )
          remaining = remove_consecutive_duplicate_points(points)
          return [] if remaining.length < 3
          return [remaining] if remaining.length == 3 && !collinear_triangle?(remaining)

          triangles = []
          while remaining.length > 3
            ear_index = remaining.each_index.find do |index|
              previous_point = remaining[(index - 1) % remaining.length]
              current_point = remaining[index]
              following_point = remaining[(index + 1) % remaining.length]
              triangle = [previous_point, current_point, following_point]

              !collinear_triangle?(triangle) &&
                !segment_has_interior_candidate?(
                  previous_point,
                  following_point,
                  candidates,
                  coordinate_space: coordinate_space
                )
            end

            unless ear_index
              raise ReconstructionError,
                    "Could not triangulate conforming boundary: " \
                    "#{remaining.map { |point| point_components_mm(point) }.inspect}"
            end

            triangles << [
              remaining[(ear_index - 1) % remaining.length],
              remaining[ear_index],
              remaining[(ear_index + 1) % remaining.length]
            ]
            remaining.delete_at(ear_index)
          end

          triangles << remaining unless collinear_triangle?(remaining)
          triangles
        end

        def segment_has_interior_candidate?(
          start_point,
          end_point,
          candidates,
          coordinate_space: :grid
        )
          start_key = triangle_point_key(start_point, coordinate_space)
          end_key = triangle_point_key(end_point, coordinate_space)

          candidates.any? do |candidate|
            candidate_key = triangle_point_key(candidate, coordinate_space)
            next false if candidate_key == start_key || candidate_key == end_key

            !point_on_segment_parameter(
              candidate,
              start_point,
              end_point,
              GRID_EPSILON_MM
            ).nil?
          end
        end

        def triangulate_polygon(points)
          compact = remove_consecutive_duplicate_points(points)
          return [] if compact.length < 3
          return [compact] if compact.length == 3

          (1...(compact.length - 1)).map do |index|
            [compact[0], compact[index], compact[index + 1]]
          end
        end

        def remove_consecutive_duplicate_points(points)
          compact = []
          points.each do |point|
            compact << point if compact.empty? || grid_indices(compact.last) != grid_indices(point)
          end

          if compact.length > 1 && grid_indices(compact.first) == grid_indices(compact.last)
            compact.pop
          end

          compact
        end

        # ----------------------------------------------------------------------
        # Rebuild and surface repair
        # ----------------------------------------------------------------------

        def erase_source_geometry(entities)
          geometry = entities.to_a.select do |item|
            item.is_a?(@face_class) || item.is_a?(@edge_class)
          end
          entities.erase_entities(geometry) unless geometry.empty?
        end

        def rebuild_triangles(entities, triangles)
          if entities.respond_to?(:fill_from_mesh) &&
             defined?(Geom::PolygonMesh)
            return rebuild_triangles_from_mesh(entities, triangles)
          end

          added_faces = 0
          skipped_collinear = 0

          triangles.each do |record|
            points = record[:points]
            if collinear_triangle?(points)
              skipped_collinear += 1
              next
            end

            face = entities.add_face(points)
            unless face&.valid?
              raise ReconstructionError,
                    "add_face failed for normalized triangle " \
                    "#{points.map { |point| point_components_mm(point) }.inspect}"
            end

            orient_face!(face, record[:source_normal])
            apply_face_metadata(face, record)
            added_faces += 1
          end

          { added_faces: added_faces, skipped_collinear: skipped_collinear }
        end

        # Sequential add_face calls allow SketchUp to auto-heal intermediate
        # closed loops into hole/cap faces before the remaining triangles are
        # added. Bulk mesh filling creates the already-validated complex in one
        # step and therefore preserves its exact edge incidence.
        def rebuild_triangles_from_mesh(entities, triangles)
          polygon_mesh = Geom::PolygonMesh.new
          point_indices = {}
          records_by_signature = {}

          triangles.each do |record|
            points = record[:points]
            if collinear_triangle?(points)
              raise ReconstructionError,
                    "Validated triangle became collinear before mesh fill: " \
                    "#{points.map { |point| point_components_mm(point) }.inspect}"
            end

            signature = triangle_signature(points)
            if records_by_signature.key?(signature)
              raise ReconstructionError,
                    "Bulk triangle rebuild received a duplicate triangle: " \
                    "#{signature.inspect}"
            end
            records_by_signature[signature] = record

            indices = points.map do |point|
              key = grid_indices(point)
              point_indices[key] ||= polygon_mesh.add_point(point)
            end
            polygon_mesh.add_polygon(indices)
          end

          filled = entities.fill_from_mesh(polygon_mesh, true, 0)
          unless filled
            raise ReconstructionError, 'fill_from_mesh rejected the normalized triangle complex'
          end

          matched = {}
          entities.grep(@face_class).each do |face|
            next unless face&.valid? && face.vertices.length == 3

            signature = triangle_signature(face.vertices.map(&:position))
            record = records_by_signature[signature]
            next unless record

            if matched.key?(signature)
              raise ReconstructionError,
                    "fill_from_mesh created duplicate triangle faces: " \
                    "#{signature.inspect}"
            end
            matched[signature] = true
            orient_face!(face, record[:source_normal])
            apply_face_metadata(face, record)
          end

          missing = records_by_signature.keys.reject { |signature| matched[signature] }
          unless missing.empty?
            raise ReconstructionError,
                  "fill_from_mesh omitted normalized triangles: " \
                  "count=#{missing.length} samples=#{missing.first(10).inspect}"
          end

          {
            added_faces: matched.length,
            skipped_collinear: 0,
            strategy: :fill_from_mesh
          }
        end

        def apply_face_metadata(face, record)
          face.material = record[:material] if face.respond_to?(:material=)
          face.back_material = record[:back_material] if face.respond_to?(:back_material=)
          face.layer = record[:layer] if face.respond_to?(:layer=) && record[:layer]
        end


        def face_record(face)
          {
            points: face.vertices.map(&:position),
            source_normal: vector_components(face.normal),
            material: face.material,
            back_material: face.back_material,
            layer: face.layer
          }
        end


        def stitch_surface_borders(entities)
          repairs = 0
          ignored_loop_signatures = {}

          loop do
            topology = geometry_counts(entities)
            break if topology[:boundary_edges].zero?

            if repairs >= MAX_STITCH_REPAIRS
              raise ReconstructionError, 'Surface-border stitch exceeded repair limit'
            end

            segment_candidate = surface_border_candidate(entities)
            if segment_candidate
              rebuild_boundary_face(entities, segment_candidate)
              repairs += 1
              next
            end

            loop_candidate = surface_border_loop_candidate(
              entities,
              ignored_loop_signatures
            )
            break unless loop_candidate

            before = geometry_counts(entities)
            face = add_face_allowing_nonplanar_failure(
              entities,
              loop_candidate[:points]
            )

            unless face&.valid?
              ignored_loop_signatures[loop_candidate[:signature]] = true
              next
            end

            after = geometry_counts(entities)
            improved = after[:boundary_edges] < before[:boundary_edges] &&
                       topology_anomaly_score(after) < topology_anomaly_score(before)

            if improved
              repairs += 1
            else
              face.erase! if face.valid?
              ignored_loop_signatures[loop_candidate[:signature]] = true
            end
          end

          { repairs: repairs }
        end

        def add_face_allowing_nonplanar_failure(entities, points)
          entities.add_face(points)
        rescue ArgumentError => e
          raise unless e.message.to_s.downcase.include?('not planar')

          nil
        end

        def surface_border_loop_candidate(entities, ignored_signatures)
          boundary_edges = entities.grep(@edge_class).select do |edge|
            edge.valid? && edge.faces.length == 1
          end
          remaining = boundary_edges.dup

          until remaining.empty?
            seed = remaining.shift
            component = [seed]
            queue = [seed]

            until queue.empty?
              edge = queue.shift
              neighbors = edge.vertices.flat_map(&:edges).select do |candidate|
                candidate.valid? &&
                  candidate.faces.length == 1 &&
                  remaining.include?(candidate)
              end

              neighbors.each do |neighbor|
                remaining.delete(neighbor)
                component << neighbor
                queue << neighbor
              end
            end

            vertices = component.flat_map(&:vertices).uniq
            next unless vertices.length >= 3

            adjacency = vertices.to_h do |vertex|
              [vertex, component.select { |edge| edge.vertices.include?(vertex) }]
            end
            next unless adjacency.values.all? { |edges| edges.length == 2 }

            ordered = ordered_closed_boundary_points(component, vertices, adjacency)
            next unless ordered

            signature = ordered.map { |point| grid_indices(point) }.sort
            next if ignored_signatures[signature]

            return { points: ordered, signature: signature }
          end

          nil
        end

        def ordered_closed_boundary_points(component, vertices, adjacency)
          ordered = []
          start_vertex = vertices.first
          current_vertex = start_vertex
          previous_edge = nil

          component.length.times do
            ordered << current_vertex.position
            next_edge = adjacency.fetch(current_vertex).find do |edge|
              edge != previous_edge
            end
            return nil unless next_edge

            current_vertex = (next_edge.vertices - [current_vertex]).first
            previous_edge = next_edge
          end

          return nil unless current_vertex == start_vertex
          return nil unless ordered.length == component.length

          ordered
        end

        def surface_border_candidate(entities)
          boundary_edges = entities.grep(@edge_class).select do |edge|
            edge.valid? && edge.faces.length == 1
          end
          boundary_vertices = boundary_edges.flat_map(&:vertices).uniq

          boundary_edges.sort_by { |edge| -edge.length.to_f }.each do |edge|
            inserted = boundary_vertices.filter_map do |vertex|
              next if edge.vertices.include?(vertex)

              parameter = point_on_segment_parameter(
                vertex.position,
                edge.start.position,
                edge.end.position,
                GRID_EPSILON_MM
              )
              [parameter, vertex.position] if parameter
            end
            next if inserted.empty?

            return {
              edge: edge,
              face: edge.faces.first,
              inserted: inserted.sort_by(&:first).map(&:last)
            }
          end

          nil
        end

        def rebuild_boundary_face(entities, candidate)
          edge = candidate[:edge]
          face = candidate[:face]
          unless edge&.valid? && face&.valid?
            raise ReconstructionError, 'Invalid surface-border stitch candidate'
          end
          unless face.loops.length == 1
            raise ReconstructionError,
                  'Surface-border stitch supports only a single outer loop'
          end

          vertices = face.outer_loop.vertices
          points = vertices.map(&:position)
          insert_index = nil
          reverse_inserted = false

          vertices.each_index do |index|
            current = vertices[index]
            following = vertices[(index + 1) % vertices.length]

            if current == edge.start && following == edge.end
              insert_index = index + 1
              break
            end
            if current == edge.end && following == edge.start
              insert_index = index + 1
              reverse_inserted = true
              break
            end
          end

          unless insert_index
            raise ReconstructionError,
                  'Surface-border edge not found in owner face loop'
          end

          inserted = reverse_inserted ? candidate[:inserted].reverse : candidate[:inserted]
          expanded = points.dup
          expanded.insert(insert_index, *inserted)
          record = face_record(face)

          face.erase!
          edge.erase! if edge.valid? && edge.faces.empty?

          rebuilt = entities.add_face(expanded)
          unless rebuilt&.valid?
            raise ReconstructionError,
                  'Surface-border owner face could not be rebuilt'
          end

          orient_face!(rebuilt, record[:source_normal])
          apply_face_metadata(rebuilt, record)
          rebuilt
        end

        # ----------------------------------------------------------------------
        # Coplanar, collinear and orientation cleanup
        # ----------------------------------------------------------------------


        def face_plane_deviation_mm(source_face, reference_face)
          plane = reference_face.plane.map(&:to_f)
          denominator = Math.sqrt(
            (plane[0]**2) + (plane[1]**2) + (plane[2]**2)
          )
          return Float::INFINITY if denominator.zero?

          source_face.vertices.map do |vertex|
            point = vertex.position
            numerator = (
              (plane[0] * point.x.to_f) +
              (plane[1] * point.y.to_f) +
              (plane[2] * point.z.to_f) +
              plane[3]
            ).abs
            numerator * MM_PER_INCH / denominator
          end.max || 0.0
        end


        def orient_shell_faces_consistently(entities)
          visited = {}
          reversed_faces = 0
          component_count = 0

          entities.grep(@face_class).each do |seed|
            next unless seed.valid?

            seed_id = stable_entity_id(seed)
            next if visited[seed_id]

            component_count += 1
            visited[seed_id] = true
            queue = [seed]

            until queue.empty?
              face = queue.shift
              face.edges.each do |edge|
                next unless edge.valid? && edge.faces.length == 2

                neighbor = (edge.faces - [face]).first
                next unless neighbor&.valid?

                neighbor_id = stable_entity_id(neighbor)
                conflict = edge.reversed_in?(face) == edge.reversed_in?(neighbor)

                if visited[neighbor_id]
                  if conflict
                    raise TopologyChangedError,
                          "Closed shell is not consistently orientable at " \
                          "edge #{stable_entity_id(edge)}"
                  end
                  next
                end

                if conflict
                  neighbor.reverse!
                  reversed_faces += 1
                end

                visited[neighbor_id] = true
                queue << neighbor
              end
            end
          end

          {
            reversed_faces: reversed_faces,
            component_count: component_count
          }
        end

        # A consistently oriented shell can still have every face pointing
        # inward. Positive signed volume is the project-wide outward convention.
        # Relative coordinates keep the determinant stable for station models
        # whose local coordinates are far from the global origin.
        def orient_shell_outward(entities)
          faces = entities.grep(@face_class).select(&:valid?)
          signed_volume_before = shell_signed_volume_in3(faces)
          if signed_volume_before.abs <= SIGNED_VOLUME_EPSILON_IN3
            raise TopologyChangedError,
                  "Closed shell has zero signed volume: #{signed_volume_before} in3"
          end

          reversed_faces = 0
          if signed_volume_before.negative?
            faces.each do |face|
              next unless face.valid?

              face.reverse!
              reversed_faces += 1
            end
          end

          signed_volume_after = shell_signed_volume_in3(faces)
          if signed_volume_after <= SIGNED_VOLUME_EPSILON_IN3
            raise TopologyChangedError,
                  "Closed shell is not outward after orientation: " \
                  "#{signed_volume_after} in3"
          end

          {
            reversed_faces: reversed_faces,
            signed_volume_before_in3: signed_volume_before,
            signed_volume_after_in3: signed_volume_after
          }
        end

        def shell_signed_volume_in3(faces)
          reference = shell_volume_reference_point(faces)
          unless reference
            raise TopologyChangedError, 'Closed shell has no mesh points for orientation'
          end

          faces.sum do |face|
            mesh = face.mesh(0)
            mesh.polygons.sum do |polygon|
              points = polygon.map { |index| mesh.point_at(index.abs) }
              next 0.0 if points.length < 3

              origin = points.first
              (1...(points.length - 1)).sum do |index|
                relative_signed_tetrahedron_volume_in3(
                  reference,
                  origin,
                  points[index],
                  points[index + 1]
                )
              end
            end
          end
        end

        def shell_volume_reference_point(faces)
          faces.each do |face|
            mesh = face.mesh(0)
            point = mesh.point_at(1)
            return point if point
          end

          nil
        end

        def relative_signed_tetrahedron_volume_in3(reference, point_a, point_b, point_c)
          vector_a = vector_between(reference, point_a)
          vector_b = vector_between(reference, point_b)
          vector_c = vector_between(reference, point_c)
          vector_dot(vector_a, vector_cross(vector_b, vector_c)) / 6.0
        end

        def orient_face!(face, source_normal)
          current_normal = vector_components(face.normal)
          face.reverse! if vector_dot(current_normal, source_normal).negative?
        end

        def stable_entity_id(entity)
          return entity.persistent_id if entity.respond_to?(:persistent_id)

          entity.object_id
        rescue StandardError
          entity.object_id
        end

        # ----------------------------------------------------------------------
        # Numeric helpers
        # ----------------------------------------------------------------------

        def normalized_target(point, axis_plane_plan = nil)
          indices = grid_indices(point)
          constraints = axis_plane_plan && axis_plane_plan[:constraints]
          (constraints && constraints[source_point_key(point)] || {}).each do |axis, target_index|
            indices[axis] = target_index
          end
          @point_factory.call(
            indices[0] * @tolerance_mm / MM_PER_INCH,
            indices[1] * @tolerance_mm / MM_PER_INCH,
            indices[2] * @tolerance_mm / MM_PER_INCH
          )
        end

        def source_point_key(point)
          [point.x.to_f, point.y.to_f, point.z.to_f]
        end

        def point_coordinate(point, axis)
          [point.x.to_f, point.y.to_f, point.z.to_f].fetch(axis)
        end

        def grid_indices(point)
          [point.x, point.y, point.z].map do |coordinate|
            ((coordinate.to_f * MM_PER_INCH) / @tolerance_mm).round
          end
        end

        def point_on_grid?(point)
          [point.x, point.y, point.z].all? do |coordinate|
            coordinate_mm = coordinate.to_f * MM_PER_INCH
            target_mm = (coordinate_mm / @tolerance_mm).round * @tolerance_mm
            (coordinate_mm - target_mm).abs <= GRID_EPSILON_MM
          end
        end

        def max_grid_residual_mm(vertices)
          vertices.flat_map do |vertex|
            point = vertex.position
            [point.x, point.y, point.z].map do |coordinate|
              coordinate_mm = coordinate.to_f * MM_PER_INCH
              target_mm = (coordinate_mm / @tolerance_mm).round * @tolerance_mm
              (coordinate_mm - target_mm).abs
            end
          end.max || 0.0
        end

        def point_on_segment_parameter(point, start_point, end_point, tolerance_mm)
          ab = [
            end_point.x.to_f - start_point.x.to_f,
            end_point.y.to_f - start_point.y.to_f,
            end_point.z.to_f - start_point.z.to_f
          ]
          ap = [
            point.x.to_f - start_point.x.to_f,
            point.y.to_f - start_point.y.to_f,
            point.z.to_f - start_point.z.to_f
          ]

          length_squared = vector_dot(ab, ab)
          return nil if length_squared.zero?

          parameter = vector_dot(ap, ab) / length_squared
          return nil unless parameter > 1.0e-9 && parameter < (1.0 - 1.0e-9)

          projection = [
            start_point.x.to_f + (ab[0] * parameter),
            start_point.y.to_f + (ab[1] * parameter),
            start_point.z.to_f + (ab[2] * parameter)
          ]

          distance_mm = Math.sqrt(
            ((point.x.to_f - projection[0])**2) +
            ((point.y.to_f - projection[1])**2) +
            ((point.z.to_f - projection[2])**2)
          ) * MM_PER_INCH

          distance_mm <= tolerance_mm ? parameter : nil
        end

        def collinear_triangle?(points)
          return true unless points.length == 3

          ab = vector_between(points[0], points[1])
          ac = vector_between(points[0], points[2])
          vector_length(vector_cross(ab, ac)) <= COLLINEAR_CROSS_EPSILON_IN2
        end

        def point_distance_mm(point_a, point_b)
          Math.sqrt(
            ((point_a.x.to_f - point_b.x.to_f)**2) +
            ((point_a.y.to_f - point_b.y.to_f)**2) +
            ((point_a.z.to_f - point_b.z.to_f)**2)
          ) * MM_PER_INCH
        end

        def point_components_mm(point)
          [point.x.to_f, point.y.to_f, point.z.to_f].map do |value|
            value * MM_PER_INCH
          end
        end

        def vector_components(vector)
          [vector.x.to_f, vector.y.to_f, vector.z.to_f]
        end

        def vector_between(point_a, point_b)
          [
            point_b.x.to_f - point_a.x.to_f,
            point_b.y.to_f - point_a.y.to_f,
            point_b.z.to_f - point_a.z.to_f
          ]
        end

        def vector_dot(vector_a, vector_b)
          (vector_a[0] * vector_b[0]) +
            (vector_a[1] * vector_b[1]) +
            (vector_a[2] * vector_b[2])
        end

        def vector_cross(vector_a, vector_b)
          [
            (vector_a[1] * vector_b[2]) - (vector_a[2] * vector_b[1]),
            (vector_a[2] * vector_b[0]) - (vector_a[0] * vector_b[2]),
            (vector_a[0] * vector_b[1]) - (vector_a[1] * vector_b[0])
          ]
        end

        def vector_length(vector)
          Math.sqrt(vector_dot(vector, vector))
        end

        def solid_volume_mm3(entity)
          entity.volume.to_f * (MM_PER_INCH**3)
        rescue StandardError
          nil
        end
      end
    end
  end
end
