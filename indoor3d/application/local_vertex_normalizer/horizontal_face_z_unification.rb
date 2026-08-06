# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        HORIZONTAL_FACE_Z_ANGLE_TOLERANCE_DEG = 0.01 unless
          const_defined?(:HORIZONTAL_FACE_Z_ANGLE_TOLERANCE_DEG, false)
        HORIZONTAL_FACE_Z_TOLERANCE_MM = 0.0025 unless
          const_defined?(:HORIZONTAL_FACE_Z_TOLERANCE_MM, false)

        private

        unless private_method_defined?(:normalize_entity_before_horizontal_face_z_unification)
          alias_method :normalize_entity_before_horizontal_face_z_unification,
                       :normalize_entity
        end

        # Bounded final-surface repair, intentionally placed immediately
        # before final_coplanar_face_merge in the alias load chain.
        #
        # Adjacent near-horizontal Faces are collected through every Face loop.
        # This explicitly includes inner loops: their edges participate in
        # adjacency and their vertices participate in the component Z target.
        # Moving the actual SketchUp Vertex objects also moves every incident Face,
        # including non-horizontal side Faces that share those vertices.
        #
        # The move is accepted only when the complete rebuilt solid still passes
        # the established exact mesh hard gate. A rejected experiment restores the
        # already-successful pre-stage normalized surface before final coplanar merge.
        def normalize_entity(entity)
          report = normalize_entity_before_horizontal_face_z_unification(entity)
          entities = entity.definition.entities

          z_report = unify_horizontal_face_component_z_before_final_coplanar!(
            entity,
            entities
          )
          report[:horizontal_face_z_unification] = z_report if report.is_a?(Hash)
          report
        end

        def unify_horizontal_face_component_z_before_final_coplanar!(entity, entities)
          baseline = snapshot_horizontal_face_z_baseline(entities)
          unless baseline
            return empty_horizontal_face_z_report(
              :baseline_snapshot_unavailable,
              restored: false
            )
          end

          plan = horizontal_face_z_unification_plan(entities)
          return plan[:report] if plan[:moves].empty?

          begin
            apply_horizontal_face_z_moves!(entities, plan[:moves])
            validation = validate_horizontal_face_z_result!(entity, entities)

            plan[:report].merge(
              applied: true,
              restored: false,
              skipped: false,
              topology_after: validation[:topology],
              grid_residual_mm: validation[:grid_residual_mm],
              final_triangle_count: validation[:triangle_count]
            )
          rescue StandardError => error
            restored = restore_horizontal_face_z_baseline!(
              entity,
              entities,
              baseline
            )
            plan[:report].merge(
              applied: false,
              restored: true,
              skipped: true,
              skip_reason: :post_move_validation_failed,
              fallback_reason: "#{error.class}: #{error.message}",
              restored_topology: restored[:topology],
              restored_grid_residual_mm: restored[:grid_residual_mm],
              restored_triangle_count: restored[:triangle_count]
            )
          end
        end

        def horizontal_face_z_unification_plan(entities)
          faces = entities.grep(@face_class).select do |face|
            face.valid? && horizontal_face_z_candidate?(face)
          end
          components = horizontal_face_z_components(faces)
          inner_loop_count = faces.sum do |face|
            [Array(face.loops).length - 1, 0].max
          end

          component_plans = components.map.with_index do |component, index|
            horizontal_face_z_component_plan(component, index)
          end
          eligible = component_plans.select { |plan| plan[:eligible] }

          targets_by_vertex = Hash.new { |hash, key| hash[key] = {} }
          eligible.each do |plan|
            plan[:vertices].each do |vertex|
              targets_by_vertex[stable_entity_id(vertex)][plan[:target_z_index]] = true
            end
          end
          conflicting_vertex_ids = targets_by_vertex.filter_map do |vertex_id, targets|
            vertex_id if targets.length > 1
          end.to_h { |vertex_id| [vertex_id, true] }

          accepted = eligible.reject do |plan|
            conflict = plan[:vertices].any? do |vertex|
              conflicting_vertex_ids.key?(stable_entity_id(vertex))
            end
            plan[:skip_reason] = :conflicting_component_targets if conflict
            plan[:eligible] = false if conflict
            conflict
          end

          moves_by_vertex = {}
          accepted.each do |plan|
            plan[:vertices].each do |vertex|
              current_z_index = horizontal_face_vertex_z_index(vertex)
              next if current_z_index == plan[:target_z_index]

              moves_by_vertex[stable_entity_id(vertex)] ||= {
                vertex: vertex,
                from_z_index: current_z_index,
                target_z_index: plan[:target_z_index]
              }
            end
          end
          moves = moves_by_vertex.values
          max_displacement_mm = moves.map do |move|
            (move[:target_z_index] - move[:from_z_index]).abs * @tolerance_mm
          end.max || 0.0

          skipped = component_plans.reject { |plan| plan[:eligible] }
          report = {
            policy: :adjacent_near_horizontal_component_existing_grid_z,
            placement: :immediately_before_final_coplanar_face_merge,
            angle_tolerance_deg: HORIZONTAL_FACE_Z_ANGLE_TOLERANCE_DEG,
            z_tolerance_mm: HORIZONTAL_FACE_Z_TOLERANCE_MM,
            candidate_face_count: faces.length,
            inner_loop_count: inner_loop_count,
            component_count: component_plans.length,
            eligible_component_count: accepted.length,
            skipped_component_count: skipped.length,
            conflicting_vertex_count: conflicting_vertex_ids.length,
            moved_vertex_count: moves.length,
            max_displacement_mm: max_displacement_mm,
            components: component_plans.first(40).map do |plan|
              horizontal_face_z_component_report(plan)
            end,
            applied: false,
            restored: false,
            skipped: moves.empty?,
            skip_reason: moves.empty? ? :no_safe_z_moves : nil
          }

          { moves: moves, report: report }
        end

        def horizontal_face_z_candidate?(face)
          normal = face.normal
          length = Math.sqrt(
            (normal.x.to_f**2) +
            (normal.y.to_f**2) +
            (normal.z.to_f**2)
          )
          return false unless length.positive?

          cosine = normal.z.to_f.abs / length
          threshold = Math.cos(
            HORIZONTAL_FACE_Z_ANGLE_TOLERANCE_DEG * Math::PI / 180.0
          )
          cosine >= threshold
        rescue StandardError
          false
        end

        # Edge adjacency is evaluated over Face#loops rather than Face#edges so
        # the inner-loop contract is explicit and testable.
        def horizontal_face_z_components(faces)
          face_by_id = faces.to_h { |face| [stable_entity_id(face), face] }
          candidate_ids = face_by_id.keys.to_h { |face_id| [face_id, true] }
          adjacency = Hash.new { |hash, key| hash[key] = {} }

          faces.each do |face|
            face_id = stable_entity_id(face)
            horizontal_face_all_loop_edges(face).each do |edge|
              edge.faces.each do |neighbor|
                neighbor_id = stable_entity_id(neighbor)
                next if neighbor_id == face_id
                next unless candidate_ids.key?(neighbor_id)

                adjacency[face_id][neighbor_id] = true
                adjacency[neighbor_id][face_id] = true
              end
            end
          end

          remaining = candidate_ids.dup
          components = []
          until remaining.empty?
            seed_id = remaining.keys.first
            queue = [seed_id]
            remaining.delete(seed_id)
            component_ids = []
            cursor = 0

            while cursor < queue.length
              current = queue[cursor]
              cursor += 1
              component_ids << current
              adjacency[current].each_key do |neighbor_id|
                next unless remaining.key?(neighbor_id)

                remaining.delete(neighbor_id)
                queue << neighbor_id
              end
            end

            components << component_ids.map { |face_id| face_by_id.fetch(face_id) }
          end
          components
        end

        def horizontal_face_z_component_plan(component, index)
          vertices = component.flat_map do |face|
            horizontal_face_all_loop_vertices(face)
          end.uniq
          z_indices = vertices.map { |vertex| horizontal_face_vertex_z_index(vertex) }
          spread_mm = if z_indices.empty?
                        0.0
                      else
                        (z_indices.max - z_indices.min) * @tolerance_mm
                      end

          plan = {
            component_index: index,
            face_ids: component.map { |face| stable_entity_id(face) },
            face_count: component.length,
            inner_loop_count: component.sum do |face|
              [Array(face.loops).length - 1, 0].max
            end,
            vertices: vertices,
            vertex_count: vertices.length,
            z_spread_mm: spread_mm,
            eligible: true,
            skip_reason: nil,
            target_z_index: nil
          }

          if component.length < 2
            plan[:eligible] = false
            plan[:skip_reason] = :singleton_component
            return plan
          end
          if vertices.empty?
            plan[:eligible] = false
            plan[:skip_reason] = :no_loop_vertices
            return plan
          end
          if spread_mm > HORIZONTAL_FACE_Z_TOLERANCE_MM
            plan[:eligible] = false
            plan[:skip_reason] = :z_spread_exceeds_tolerance
            return plan
          end

          plan[:target_z_index] = horizontal_face_component_target_z_index(z_indices)
          plan
        rescue StandardError => error
          {
            component_index: index,
            face_ids: [],
            face_count: component.length,
            inner_loop_count: 0,
            vertices: [],
            vertex_count: 0,
            z_spread_mm: nil,
            eligible: false,
            skip_reason: :component_analysis_failed,
            error: "#{error.class}: #{error.message}",
            target_z_index: nil
          }
        end

        # Select an existing grid Z value. Prefer the mode; break ties by the
        # nearest value to the component median and then the lower grid index.
        def horizontal_face_component_target_z_index(z_indices)
          counts = z_indices.tally
          maximum_count = counts.values.max
          candidates = counts.select { |_z, count| count == maximum_count }.keys
          ordered = z_indices.sort
          median = if ordered.length.odd?
                     ordered[ordered.length / 2].to_f
                   else
                     (ordered[(ordered.length / 2) - 1] + ordered[ordered.length / 2]) / 2.0
                   end
          candidates.min_by { |z_index| [(z_index - median).abs, z_index] }
        end

        def horizontal_face_all_loop_edges(face)
          Array(face.loops).flat_map { |loop| Array(loop.edges) }.uniq
        end

        def horizontal_face_all_loop_vertices(face)
          Array(face.loops).flat_map { |loop| Array(loop.vertices) }.uniq
        end

        def horizontal_face_vertex_z_index(vertex)
          ((vertex.position.z.to_f * MM_PER_INCH) / @tolerance_mm).round
        end

        def apply_horizontal_face_z_moves!(entities, moves)
          vertices = moves.map { |move| move.fetch(:vertex) }
          vectors = moves.map do |move|
            delta_mm = (move.fetch(:target_z_index) - move.fetch(:from_z_index)) *
              @tolerance_mm
            @vector_factory.call(0.0, 0.0, delta_mm / MM_PER_INCH)
          end
          entities.transform_by_vectors(vertices, vectors)
        end

        def snapshot_horizontal_face_z_baseline(entities)
          duplicate_diagnostics = {}
          triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: duplicate_diagnostics,
            snapshot_role: :before_horizontal_face_z_unification
          )
          triangles, = discard_collapsed_triangle_records(triangles)
          validate_normalized_triangle_mesh!(triangles)
          triangles
        rescue StandardError
          nil
        end

        def validate_horizontal_face_z_result!(entity, entities)
          topology = geometry_counts(entities)
          validate_rebuilt_entity!(entity, topology)

          residual_mm = max_grid_residual_mm(geometry_vertices(entities))
          if residual_mm > GRID_EPSILON_MM
            raise TopologyChangedError,
                  "Horizontal Z unification left off-grid vertices: " \
                  "residual=#{residual_mm} mm"
          end

          duplicate_diagnostics = {}
          triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: duplicate_diagnostics,
            snapshot_role: :after_horizontal_face_z_unification
          )
          triangles, = discard_collapsed_triangle_records(triangles)
          validate_normalized_triangle_mesh!(triangles)

          {
            topology: topology,
            grid_residual_mm: residual_mm,
            triangle_count: triangles.length
          }
        end

        def restore_horizontal_face_z_baseline!(entity, entities, baseline)
          erase_source_geometry(entities)
          build = rebuild_triangles(entities, baseline)
          unless build[:added_faces] == baseline.length &&
                 build[:skipped_collinear].zero?
            raise ReconstructionError,
                  "Could not restore surface after horizontal Z unification " \
                  "rejection: #{build.inspect}"
          end

          repair_reverse_faces(entities)
          topology = geometry_counts(entities)
          validate_rebuilt_entity!(entity, topology)

          residual_mm = max_grid_residual_mm(geometry_vertices(entities))
          if residual_mm > GRID_EPSILON_MM
            raise TopologyChangedError,
                  "Restored horizontal Z baseline is off grid: " \
                  "residual=#{residual_mm} mm"
          end

          duplicate_diagnostics = {}
          triangles = normalized_triangle_snapshot(
            entities,
            duplicate_diagnostics: duplicate_diagnostics,
            snapshot_role: :restored_after_horizontal_face_z_unification_failure
          )
          triangles, = discard_collapsed_triangle_records(triangles)
          validate_normalized_triangle_mesh!(triangles)

          {
            topology: topology,
            grid_residual_mm: residual_mm,
            triangle_count: triangles.length
          }
        end

        def empty_horizontal_face_z_report(reason, restored:)
          {
            policy: :adjacent_near_horizontal_component_existing_grid_z,
            placement: :immediately_before_final_coplanar_face_merge,
            angle_tolerance_deg: HORIZONTAL_FACE_Z_ANGLE_TOLERANCE_DEG,
            z_tolerance_mm: HORIZONTAL_FACE_Z_TOLERANCE_MM,
            candidate_face_count: 0,
            inner_loop_count: 0,
            component_count: 0,
            eligible_component_count: 0,
            skipped_component_count: 0,
            conflicting_vertex_count: 0,
            moved_vertex_count: 0,
            max_displacement_mm: 0.0,
            components: [],
            applied: false,
            restored: restored,
            skipped: true,
            skip_reason: reason
          }
        end

        def horizontal_face_z_component_report(plan)
          {
            component_index: plan[:component_index],
            face_ids: plan[:face_ids],
            face_count: plan[:face_count],
            inner_loop_count: plan[:inner_loop_count],
            vertex_count: plan[:vertex_count],
            z_spread_mm: plan[:z_spread_mm],
            target_z_mm:
              (plan[:target_z_index] * @tolerance_mm if plan[:target_z_index]),
            eligible: plan[:eligible],
            skip_reason: plan[:skip_reason],
            error: plan[:error]
          }
        end
      end
    end
  end
end
