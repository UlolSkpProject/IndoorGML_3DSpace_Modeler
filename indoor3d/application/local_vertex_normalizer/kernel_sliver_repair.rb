# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

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
      end
    end
  end
end
