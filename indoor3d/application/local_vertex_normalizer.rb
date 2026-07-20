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

        STRICT_COPLANAR_TOLERANCE_MM = 0.000001
        STRICT_COPLANAR_ANGLE_TOLERANCE_DEG = 0.001

        COPLANAR_TOLERANCE_MM = 0.01
        COPLANAR_ANGLE_TOLERANCE_DEG = 0.01
        AXIS_PLANE_ANGLE_TOLERANCE_DEG = COPLANAR_ANGLE_TOLERANCE_DEG

        COLLINEAR_CROSS_EPSILON_IN2 = 1.0e-12
        MAX_STITCH_REPAIRS = 1_000
        MAX_COPLANAR_PASSES = 20
        MAX_COLLINEAR_REPAIRS = 1_000
        SIGNED_VOLUME_EPSILON_IN3 = 1.0e-12
        MM_PER_INCH = 25.4

        class Error < StandardError; end
        class ReconstructionError < Error; end
        class DestructiveCoplanarCleanupError < ReconstructionError; end
        class TopologyChangedError < Error; end
        class OperationError < Error; end

        class << self
          def normalize(entity, tolerance_mm = DEFAULT_TOLERANCE_MM)
            new(tolerance_mm).normalize(entity)
          end

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

        # Returns true when every definition-local vertex lies on the requested
        # millimetre grid and no two topologically distinct vertices occupy the
        # same grid coordinate.
        #
        # This is intentionally a fast coordinate/uniqueness predicate. It is not
        # a complete solid-validity or cleanup predicate.
        def normalized?(entity)
          return false unless valid_entity_definition?(entity)

          entities = entity.definition.entities
          vertices = geometry_vertices(entities)
          return false if vertices.empty?

          axis_plane_plan = axis_plane_normalization_plan(entities)
          occupied = {}
          vertices.each do |vertex|
            point = vertex.position
            return false unless point_on_grid?(point)
            target = normalized_target(point, axis_plane_plan)
            return false if point_distance_mm(point, target) > GRID_EPSILON_MM

            key = grid_indices(target)
            return false if occupied.key?(key)

            occupied[key] = true
          end

          # Coordinate normalization is not complete while an axis-plane
          # family is still split by removable internal edges. This also makes
          # the export guard normalize older, already-snapped triangle meshes.
          return false unless axis_plane_merge_candidate_edges(entities).empty?

          true
        rescue StandardError
          false
        end

        # Rebuilds one manifold solid on the requested local-coordinate grid.
        # The complete reconstruction owns one SketchUp operation so every
        # mutation, including make_unique, is rolled back on failure.
        def normalize(entity)
          validate_entity!(entity)
          with_normalization_operation(entity) do
            normalize_entity(entity)
          end
        end

        private

        def normalize_entity(entity)
          ensure_unique_definition(entity)

          entities = entity.definition.entities
          topology_before = geometry_counts(entities)
          volume_before_mm3 = solid_volume_mm3(entity)
          source_vertices = geometry_vertices(entities)
          axis_plane_plan = axis_plane_normalization_plan(entities)
          vertex_metrics = normalized_vertex_metrics(source_vertices, axis_plane_plan)

          if vertex_metrics[:unique_target_count] != source_vertices.length
            raise ReconstructionError,
                  "Normalization would merge distinct vertices: " \
                  "source=#{source_vertices.length} " \
                  "targets=#{vertex_metrics[:unique_target_count]}"
          end

          source_duplicate_diagnostics = {}
          source_triangles = normalized_triangle_snapshot(
            entities,
            axis_plane_plan,
            duplicate_diagnostics: source_duplicate_diagnostics
          )
          source_triangles, source_degenerate_repair =
            repair_degenerate_source_triangles(source_triangles)
          validate_normalized_triangle_shapes!(source_triangles)
          conforming_triangles = conforming_triangle_snapshot(source_triangles)
          conforming_triangles, conforming_degenerate_repair =
            repair_degenerate_source_triangles(conforming_triangles)
          if conforming_triangles.empty?
            raise ReconstructionError, "No reconstructable faces found for #{entity_label(entity)}"
          end

          mesh_validation = validate_normalized_triangle_mesh!(conforming_triangles)

          erase_source_geometry(entities)
          build = rebuild_triangles(entities, conforming_triangles)
          unless build[:added_faces] == conforming_triangles.length &&
                 build[:skipped_collinear].zero?
            raise ReconstructionError,
                  "Normalized triangle rebuild was incomplete: #{build.inspect}"
          end


          rebuilt_duplicate_diagnostics = {}
          rebuilt_triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: rebuilt_duplicate_diagnostics
          )
          rebuilt_triangles, rebuilt_degenerate_repair =
            repair_degenerate_source_triangles(rebuilt_triangles)
          validate_normalized_triangle_mesh!(rebuilt_triangles)
          verify_triangle_rebuild!(conforming_triangles, rebuilt_triangles)

          consistency_orientation = orient_shell_faces_consistently(entities)
          unless consistency_orientation[:component_count] == 1
            raise TopologyChangedError,
                  "Outward orientation requires one connected shell: " \
                  "components=#{consistency_orientation[:component_count]}"
          end


          axis_plane_merge = merge_axis_plane_faces(entities)

          outward_orientation = orient_shell_outward(entities)
          orientation = {
            reversed_faces: consistency_orientation[:reversed_faces] +
              outward_orientation[:reversed_faces],
            consistency_reversed_faces: consistency_orientation[:reversed_faces],
            shell_component_count: consistency_orientation[:component_count],
            outward_reversed_faces: outward_orientation[:reversed_faces],
            signed_volume_before_mm3: outward_orientation[:signed_volume_before_in3] *
              (MM_PER_INCH**3),
            signed_volume_after_mm3: outward_orientation[:signed_volume_after_in3] *
              (MM_PER_INCH**3)
          }

          topology_after = geometry_counts(entities)
          validate_rebuilt_entity!(entity, topology_after)

          final_vertices = geometry_vertices(entities)
          residual_mm = max_grid_residual_mm(final_vertices)
          if residual_mm > GRID_EPSILON_MM
            raise TopologyChangedError,
                  "Rebuilt vertices are off the #{@tolerance_mm} mm grid: residual=#{residual_mm} mm"
          end

          final_duplicate_diagnostics = {}
          final_triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: final_duplicate_diagnostics
          )
          final_triangles, final_degenerate_repair =
            repair_degenerate_source_triangles(final_triangles)
          final_mesh_validation = validate_normalized_triangle_mesh!(final_triangles)

          degenerate_repair = aggregate_degenerate_repair_reports(
            source: source_degenerate_repair,
            conforming: conforming_degenerate_repair,
            rebuilt: rebuilt_degenerate_repair,
            final: final_degenerate_repair
          )

          build_normalization_report(
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
            duplicate_diagnostics: {
              source: source_duplicate_diagnostics,
              rebuilt: rebuilt_duplicate_diagnostics,
              final: final_duplicate_diagnostics
            },
            residual_mm: residual_mm
          )
        end

        def with_normalization_operation(entity)
          model = normalization_model(entity)
          operation_started = false

          begin
            operation_started = model.start_operation(
              'Normalize IndoorGML local vertices',
              true
            )
            unless operation_started
              raise OperationError, 'Failed to start local vertex normalization operation'
            end

            result = yield
            committed = model.commit_operation
            if committed == false
              raise OperationError, 'Failed to commit local vertex normalization operation'
            end

            operation_started = false
            result
          rescue StandardError => error
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
            max_displacement_mm: vertex_metrics[:max_displacement_mm],
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
                phase: :degenerate_triangle_retriangulation,
                repaired_triangles: degenerate_repair[:repaired_triangles],
                replaced_pairs: degenerate_repair[:replaced_pairs],
                stages: degenerate_repair[:stages]
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
            heuristic_repairs_enabled: false,
            volume_before_mm3: volume_before_mm3,
            volume_after_mm3: solid_volume_mm3(entity),
            topology_before: topology_before,
            topology: topology_after,
            topology_changed: topology_before != topology_after,
            manifold: true
          }
        end

        # Builds the normalized shell and applies only the strict coplanar cleanup.
        # If strict cleanup damages topology, the geometry is rebuilt without it.
        def rebuild_normalized_base(entities, triangles, entity)
          strict_fallback_reason = nil

          begin
            result = build_normalized_surface(
              entities,
              triangles,
              run_strict_cleanup: true
            )
          rescue DestructiveCoplanarCleanupError => e
            strict_fallback_reason = e.message
            result = build_normalized_surface(
              entities,
              triangles,
              run_strict_cleanup: false,
              strict_fallback_reason: strict_fallback_reason
            )
          end

          topology = result.fetch(:topology)
          if !closed_topology?(topology) && result.dig(:strict_coplanar, :removed_edges).to_i.positive?
            strict_fallback_reason = "Strict coplanar cleanup changed topology: #{topology.inspect}"
            result = build_normalized_surface(
              entities,
              triangles,
              run_strict_cleanup: false,
              strict_fallback_reason: strict_fallback_reason
            )
            topology = result.fetch(:topology)
          end

          unless closed_topology?(topology)
            raise TopologyChangedError,
                  "Rebuilt surface is open before broad coplanar cleanup: " \
                  "#{entity_label(entity)} #{topology.inspect}"
          end

          result.delete(:topology)
          result
        end

        def build_normalized_surface(
          entities,
          triangles,
          run_strict_cleanup:,
          strict_fallback_reason: nil
        )
          erase_source_geometry(entities)
          build = rebuild_triangles(entities, triangles)
          overlap_repair = remove_redundant_overlap_triangles(entities)
          pre_stitch = stitch_surface_borders(entities)

          strict_coplanar = if run_strict_cleanup
                              remove_coplanar_shared_edges(
                                entities,
                                plane_tolerance_mm: STRICT_COPLANAR_TOLERANCE_MM,
                                angle_tolerance_deg: STRICT_COPLANAR_ANGLE_TOLERANCE_DEG
                              )
                            else
                              empty_coplanar_cleanup_report(
                                fallback_reason: strict_fallback_reason
                              )
                            end

          post_stitch = stitch_surface_borders(entities)
          topology = geometry_counts(entities)

          if closed_surface?(topology) && topology[:orientation_conflicts].to_i.positive?
            orient_shell_faces_consistently(entities)
            topology = geometry_counts(entities)
          end

          {
            build: build,
            overlap_repair: overlap_repair,
            pre_stitch: pre_stitch,
            strict_coplanar: strict_coplanar,
            post_stitch: post_stitch,
            topology: topology
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

        def entity_label_from_face(face)
          persistent_id = face.respond_to?(:persistent_id) ? face.persistent_id : nil
          "face_persistent_id=#{persistent_id.inspect}"
        rescue StandardError
          face.class.to_s
        end

        # ----------------------------------------------------------------------
        # Grid projection and triangle snapshots
        # ----------------------------------------------------------------------

        # Builds exact local X/Y/Z plane constraints before ordinary grid
        # projection. Only faces connected through an actual shared edge
        # participate in the same family. Coordinate distance is deliberately
        # not a grouping condition: adjacent subdivisions of one intended plane
        # are unified, while disconnected parallel planes such as a floor and a
        # ceiling remain independent.
        def axis_plane_normalization_plan(entities)
          records = entities.grep(@face_class).filter_map do |face|
            axis_plane_face_record(face)
          end
          constraints = {}
          clusters = []

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
              max_target_displacement = coordinates.map do |coordinate|
                (coordinate - target_mm).abs
              end.max || 0.0

              component_vertices.each do |vertex|
                key = source_point_key(vertex.position)
                constraints[key] ||= {}
                existing = constraints[key][axis]
                if !existing.nil? && existing != target_index
                  raise ReconstructionError,
                        "Conflicting axis-plane constraints at #{key.inspect}: " \
                        "axis=#{axis} targets=#{existing},#{target_index}"
                end
                constraints[key][axis] = target_index
              end
              clusters << {
                axis: axis,
                target_index: target_index,
                target_mm: target_mm,
                face_count: component.length,
                vertex_count: component_vertices.length,
                source_spread_mm: spread,
                max_displacement_mm: max_target_displacement
              }
            end
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
                                         .transform_values(&:length)
          }
        end

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

        # Removes only the internal edges of rebuilt local-axis plane
        # families. Plane equality is exact on the integer normalization grid;
        # no distance tolerance is used here. Disconnected parallel surfaces
        # never become candidates because there is no shared edge to erase.
        def merge_axis_plane_faces(entities)
          removed_edges = 0
          merged_faces = 0
          pass_reports = []

          MAX_COPLANAR_PASSES.times do |pass_index|
            candidates = axis_plane_merge_candidate_edges(entities)
            break if candidates.empty?

            pass_removed = 0
            candidates.each do |edge|
              next unless edge&.valid?
              next unless axis_plane_merge_candidate_edge?(edge)

              faces_before = entities.grep(@face_class).length
              edge.erase!
              faces_after = entities.grep(@face_class).length
              face_reduction = faces_before - faces_after

              unless face_reduction == 1
                raise DestructiveCoplanarCleanupError,
                      "Axis-plane internal edge merge was destructive: " \
                      "faces #{faces_before} -> #{faces_after}"
              end

              pass_removed += 1
              removed_edges += 1
              merged_faces += face_reduction
            end

            break if pass_removed.zero?

            pass_reports << {
              pass: pass_index + 1,
              removed_edges: pass_removed
            }
          end

          remaining = axis_plane_merge_candidate_edges(entities)
          unless remaining.empty?
            raise DestructiveCoplanarCleanupError,
                  "Axis-plane face merge did not converge: " \
                  "remaining_internal_edges=#{remaining.length}"
          end

          topology = geometry_counts(entities)
          unless closed_topology?(topology)
            raise TopologyChangedError,
                  "Axis-plane face merge damaged topology: #{topology.inspect}"
          end

          {
            removed_edges: removed_edges,
            merged_faces: merged_faces,
            passes: pass_reports,
            topology: topology
          }
        end

        def axis_plane_merge_candidate_edges(entities)
          entities.grep(@edge_class).select do |edge|
            axis_plane_merge_candidate_edge?(edge)
          end
        end

        def axis_plane_merge_candidate_edge?(edge)
          return false unless edge&.valid? && edge.faces.length == 2

          face_a, face_b = edge.faces
          plane_a = exact_axis_plane_key(face_a)
          return false if plane_a.nil? || plane_a != exact_axis_plane_key(face_b)

          vector_dot(
            vector_components(face_a.normal),
            vector_components(face_b.normal)
          ).positive?
        rescue StandardError
          false
        end

        def exact_axis_plane_key(face)
          return nil unless face&.valid?

          axis = axis_aligned_normal_axis(face.normal)
          return nil if axis.nil?

          indices = face.vertices.map do |vertex|
            grid_indices(vertex.position)[axis]
          end.uniq
          return nil unless indices.length == 1

          [axis, indices.first]
        rescue StandardError
          nil
        end

        def median_value(values)
          sorted = Array(values).map(&:to_f).sort
          raise ReconstructionError, 'Axis-plane family has no coordinates' if sorted.empty?

          middle = sorted.length / 2
          return sorted[middle] if sorted.length.odd?

          (sorted[middle - 1] + sorted[middle]) / 2.0
        end

        def normalized_vertex_metrics(vertices, axis_plane_plan = nil)
          unique_targets = {}
          moved_count = 0
          max_displacement_mm = 0.0

          vertices.each do |vertex|
            target = normalized_target(vertex.position, axis_plane_plan)
            unique_targets[grid_indices(target)] = true
            displacement_mm = point_distance_mm(vertex.position, target)
            moved_count += 1 if displacement_mm > GRID_EPSILON_MM
            max_displacement_mm = displacement_mm if displacement_mm > max_displacement_mm
          end

          {
            unique_target_count: unique_targets.length,
            moved_count: moved_count,
            max_displacement_mm: max_displacement_mm
          }
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
          triangles = []
          signatures = {}
          diagnostics = duplicate_diagnostics || {}
          diagnostics[:duplicate_count] = 0
          diagnostics[:samples] = []

          entities.grep(@face_class).each do |face|
            mesh = face.mesh(0)
            source_face_key = stable_entity_id(face)
            mesh.polygons.each_with_index do |polygon, polygon_index|
              points = polygon.map do |index|
                normalized_target(mesh.point_at(index.abs), axis_plane_plan)
              end

              triangulate_polygon(points).each do |triangle_points|
                signature = triangle_signature(triangle_points)
                if signatures.key?(signature)
                  diagnostics[:duplicate_count] += 1
                  if diagnostics[:samples].length < 10
                    kept = signatures.fetch(signature)
                    diagnostics[:samples] << {
                      signature: signature,
                      kept_face_key: kept[:source_face_key],
                      kept_polygon_index: kept[:source_polygon_index],
                      duplicate_face_key: source_face_key,
                      duplicate_polygon_index: polygon_index
                    }
                  end
                  next
                end

                record = {
                  points: triangle_points,
                  source_normal: vector_components(face.normal),
                  material: face.material,
                  back_material: face.back_material,
                  layer: face.layer,
                  source_face_key: source_face_key,
                  source_polygon_index: polygon_index
                }
                signatures[signature] = record
                triangles << record
              end
            end
          end

          triangles
        end

        # Replaces a zero-area triangle A-B-C (B lies on A-C) together with
        # the non-degenerate triangle A-C-D on the other side of the internal
        # triangulation diagonal. The replacement uses B-D:
        #   (A,B,C) + (A,C,D) -> (A,B,D) + (B,C,D)
        # No vertex is moved or removed.
        def repair_degenerate_source_triangles(triangle_records)
          working = triangle_records.map(&:dup)
          repaired_triangles = 0
          replaced_pairs = 0

          loop do
            degenerate_indices = working.each_index.select do |index|
              degenerate_triangle_record?(working[index])
            end
            break if degenerate_indices.empty?

            repair = nil
            degenerate_indices.each do |degenerate_index|
              degenerate = working[degenerate_index]
              split = collinear_triangle_split(degenerate[:points])
              next unless split

              neighbor_indices = working.each_index.select do |candidate_index|
                next false if candidate_index == degenerate_index

                candidate = working[candidate_index]
                next false unless candidate[:source_face_key] == degenerate[:source_face_key]
                next false if degenerate_triangle_record?(candidate)

                candidate_keys = candidate[:points].map { |point| grid_indices(point) }
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
                    "points=#{record[:points].map { |point| grid_indices(point) }.inspect}"
            end

            degenerate = working[repair[:degenerate_index]]
            neighbor = working[repair[:neighbor_index]]
            split = repair[:split]
            neighbor_points_by_key = neighbor[:points].each_with_object({}) do |point, points|
              points[grid_indices(point)] = point
            end
            opposite_entry = neighbor_points_by_key.find do |key, _point|
              key != split[:endpoint_a_key] && key != split[:endpoint_c_key]
            end
            unless opposite_entry
              raise ReconstructionError,
                    "Degenerate triangle neighbor has no opposite vertex: " \
                    "#{neighbor[:points].map { |point| grid_indices(point) }.inspect}"
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
              triangle = record[:points].map { |point| grid_indices(point) }
              if triangle.uniq.length != 3 ||
                 integer_zero_vector?(integer_triangle_normal(triangle))
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
              signatures[triangle_signature(record[:points])] = true
            end
            replacements.each do |record|
              signature = triangle_signature(record[:points])
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

        def degenerate_triangle_record?(record)
          triangle = record[:points].map { |point| grid_indices(point) }
          triangle.uniq.length != 3 ||
            integer_zero_vector?(integer_triangle_normal(triangle))
        end

        def collinear_triangle_split(points)
          keys = points.map { |point| grid_indices(point) }
          return nil unless keys.uniq.length == 3
          return nil unless integer_zero_vector?(integer_triangle_normal(keys))

          keys.each_index do |middle_index|
            endpoint_indices = keys.each_index.reject { |index| index == middle_index }
            endpoint_a_index, endpoint_c_index = endpoint_indices
            middle_key = keys[middle_index]
            endpoint_a_key = keys[endpoint_a_index]
            endpoint_c_key = keys[endpoint_c_index]
            next unless integer_point_between?(
              middle_key,
              endpoint_a_key,
              endpoint_c_key
            )

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

        def conforming_triangle_snapshot(source_triangles)
          unique_points = {}
          source_triangles.each do |record|
            record[:points].each do |point|
              unique_points[grid_indices(point)] ||= point
            end
          end

          candidates = unique_points.values
          signatures = {}

          source_triangles.flat_map do |record|
            next [] if collinear_triangle?(record[:points])

            boundary = triangle_boundary_with_segment_vertices(
              record[:points],
              candidates
            )

            triangulate_convex_boundary(boundary, candidates).map do |points|
              signature = triangle_signature(points)
              if signatures.key?(signature)
                raise ReconstructionError,
                      "Duplicate conforming triangle detected: #{signature.inspect}"
              end

              signatures[signature] = true
              record.merge(points: points)
            end
          end
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

          tested_pairs = validate_triangle_intersections!(triangles)

          {
            vertex_count: vertices.length,
            edge_count: edge_incidence.length,
            triangle_count: triangles.length,
            component_count: component_count,
            tested_triangle_pairs: tested_pairs
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

        def triangle_boundary_with_segment_vertices(points, candidates)
          boundary = []

          3.times do |index|
            start_point = points[index]
            end_point = points[(index + 1) % 3]
            boundary << start_point

            inserted = candidates.filter_map do |candidate|
              candidate_key = grid_indices(candidate)
              next if candidate_key == grid_indices(start_point)
              next if candidate_key == grid_indices(end_point)

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
        def triangulate_convex_boundary(points, candidates = points)
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
                  candidates
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

        def segment_has_interior_candidate?(start_point, end_point, candidates)
          start_key = grid_indices(start_point)
          end_key = grid_indices(end_point)

          candidates.any? do |candidate|
            candidate_key = grid_indices(candidate)
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

        def apply_face_metadata(face, record)
          face.material = record[:material] if face.respond_to?(:material=)
          face.back_material = record[:back_material] if face.respond_to?(:back_material=)
          face.layer = record[:layer] if face.respond_to?(:layer=) && record[:layer]
        end

        # SketchUp can create a triangular overlap cap while normalized faces are
        # added. The cap is removed only when doing so reduces topology anomalies.
        def remove_redundant_overlap_triangles(entities)
          removed_faces = 0
          repairs = []
          ignored_signatures = {}

          loop do
            before = geometry_counts(entities)
            candidate = entities.grep(@face_class).find do |face|
              next false unless face.valid? && face.edges.length == 3

              signature = triangle_signature(face.vertices.map(&:position))
              next false if ignored_signatures[signature]

              incidence = face.edges.map { |edge| edge.faces.length }
              overused_count = incidence.count { |count| count > 2 }
              boundary_count = incidence.count { |count| count == 1 }
              (overused_count >= 2 && boundary_count >= 1) || overused_count == 3
            end
            break unless candidate

            signature = triangle_signature(candidate.vertices.map(&:position))
            record = face_record(candidate)
            points_mm = candidate.vertices.map do |vertex|
              point_components_mm(vertex.position)
            end

            candidate.erase!
            erase_wire_edges(entities)
            after = geometry_counts(entities)

            unless topology_anomaly_score(after) < topology_anomaly_score(before)
              restored = entities.add_face(record[:points])
              unless restored&.valid?
                raise ReconstructionError,
                      "Redundant overlap triangle repair could not restore " \
                      "rejected candidate: #{before.inspect} -> #{after.inspect}"
              end

              orient_face!(restored, record[:source_normal])
              apply_face_metadata(restored, record)
              ignored_signatures[signature] = true
              next
            end

            removed_faces += 1
            repairs << { points_mm: points_mm, before: before, after: after }
          end

          { removed_faces: removed_faces, repairs: repairs }
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

        def erase_wire_edges(entities)
          entities.grep(@edge_class).each do |edge|
            edge.erase! if edge.valid? && edge.faces.empty?
          end
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

        def remove_coplanar_shared_edges(
          entities,
          plane_tolerance_mm:,
          angle_tolerance_deg:
        )
          removed = 0
          unchanged = 0
          ignored_edge_ids = {}
          pass_reports = []
          max_deviation_mm = 0.0
          max_angle_deg = 0.0

          MAX_COPLANAR_PASSES.times do |pass_index|
            candidates = entities.grep(@edge_class).filter_map do |edge|
              next if ignored_edge_ids[stable_entity_id(edge)]

              coplanar_edge_metrics(
                edge,
                plane_tolerance_mm: plane_tolerance_mm,
                angle_tolerance_deg: angle_tolerance_deg
              )
            end
            break if candidates.empty?

            pass_removed = 0
            candidates.each do |entry|
              edge = entry[:edge]
              next unless edge&.valid? && edge.faces.length == 2

              current = coplanar_edge_metrics(
                edge,
                plane_tolerance_mm: plane_tolerance_mm,
                angle_tolerance_deg: angle_tolerance_deg
              )
              next unless current

              faces_before = entities.grep(@face_class).length
              edge_id = stable_entity_id(edge)

              begin
                edge.erase!
              rescue ArgumentError => e
                ignored_edge_ids[edge_id] = true
                unchanged += 1
                next if e.message.to_s.downcase.include?('not planar')

                raise
              end

              faces_after = entities.grep(@face_class).length
              face_reduction = faces_before - faces_after

              if face_reduction.zero?
                ignored_edge_ids[edge_id] = true
                unchanged += 1
                next
              end

              unless face_reduction == 1
                raise DestructiveCoplanarCleanupError,
                      "Coplanar edge removal was destructive at " \
                      "tolerance=#{plane_tolerance_mm}mm " \
                      "angle=#{current[:angle_deg]}deg " \
                      "deviation=#{current[:plane_deviation_mm]}mm: " \
                      "faces #{faces_before} -> #{faces_after}"
              end

              pass_removed += 1
              removed += 1
              max_deviation_mm = [max_deviation_mm, current[:plane_deviation_mm]].max
              max_angle_deg = [max_angle_deg, current[:angle_deg]].max
            end

            break if pass_removed.zero?

            pass_reports << { pass: pass_index + 1, removed_edges: pass_removed }
          end

          {
            removed_edges: removed,
            unchanged_edges: unchanged,
            passes: pass_reports,
            max_plane_deviation_mm: max_deviation_mm,
            max_angle_deg: max_angle_deg,
            fallback_reason: nil
          }
        end

        def coplanar_edge_metrics(edge, plane_tolerance_mm:, angle_tolerance_deg:)
          return nil unless edge&.valid? && edge.faces.length == 2

          face_a, face_b = edge.faces
          dot = vector_dot(
            vector_components(face_a.normal),
            vector_components(face_b.normal)
          )
          return nil unless dot.positive?

          clamped_dot = [[dot, -1.0].max, 1.0].min
          angle_deg = Math.acos(clamped_dot) * 180.0 / Math::PI
          return nil if angle_deg > angle_tolerance_deg

          deviation_mm = [
            face_plane_deviation_mm(face_a, face_b),
            face_plane_deviation_mm(face_b, face_a)
          ].max
          return nil if deviation_mm > plane_tolerance_mm

          {
            edge: edge,
            plane_deviation_mm: deviation_mm,
            angle_deg: angle_deg
          }
        rescue StandardError
          nil
        end

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

        def remove_unbranched_collinear_vertices(entities)
          removed = 0

          MAX_COLLINEAR_REPAIRS.times do
            candidate = geometry_vertices(entities).find do |vertex|
              removable_collinear_vertex?(vertex)
            end
            break unless candidate

            rebuild_faces_without_vertex(entities, candidate)
            removed += 1
          end

          { removed_vertices: removed }
        end

        def removable_collinear_vertex?(vertex)
          return false unless vertex.valid?
          return false unless vertex.edges.length == 2
          return false unless vertex.faces.length == 2
          return false unless vertex.faces.all? do |face|
            face.valid? && face.loops.length == 1 && face.vertices.length > 3
          end

          point = vertex.position
          other_points = vertex.edges.map do |edge|
            (edge.vertices - [vertex]).first.position
          end

          !point_on_segment_parameter(
            point,
            other_points[0],
            other_points[1],
            GRID_EPSILON_MM
          ).nil?
        rescue StandardError
          false
        end

        def rebuild_faces_without_vertex(entities, vertex)
          records = vertex.faces.map do |face|
            record = face_record(face)
            record[:points] = face.outer_loop.vertices.reject do |item|
              item == vertex
            end.map(&:position)
            record
          end

          obsolete_edges = vertex.edges.to_a
          vertex.faces.to_a.each do |face|
            face.erase! if face.valid?
          end
          obsolete_edges.each do |edge|
            edge.erase! if edge.valid? && edge.faces.empty?
          end

          records.each do |record|
            face = entities.add_face(record[:points])
            unless face&.valid?
              raise ReconstructionError,
                    'Collinear vertex cleanup could not rebuild adjacent face'
            end

            orient_face!(face, record[:source_normal])
            apply_face_metadata(face, record)
          end
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
