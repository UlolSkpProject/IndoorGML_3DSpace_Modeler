# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_boundary_dp_global_edge_support_repair'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityExplicitOverlapToleranceHelpers
          private

          def apply_explicit_overlap_tolerance_to_pair_result(
            result,
            group1,
            group2,
            key
          )
            points = overlap_tolerance_point_cache.delete(key)
            return result unless result.is_a?(Hash)
            return result unless result[:status].to_s == 'reproduced'

            candidates = shared_face_candidates(
              entity_faces(group1),
              entity_faces(group2)
            )
            resolve_reproduced_intersection_with_overlap_tolerance(
              result,
              candidates,
              points
            )
          end

          def capture_overlap_tolerance_intersection_points(result, cell_ids)
            ids = Array(cell_ids)
            return false unless ids.length == 2
            return false if ids.any? { |cell_id| cell_id.to_s.empty? }
            return false unless result&.valid?

            faces = result.definition.entities.grep(Sketchup::Face).select(&:valid?)
            points = intersection_face_points(result, faces)
            return false if points.empty?

            overlap_tolerance_point_cache[pair_key(ids[0], ids[1])] = points
            true
          rescue StandardError
            false
          end

          def overlap_tolerance_point_cache
            @overlap_tolerance_point_cache ||= {}
          end

          def resolve_reproduced_intersection_with_overlap_tolerance(
            intersection,
            candidates,
            points
          )
            point_list = Array(points)
            candidate_list = Array(candidates)
            return intersection if point_list.empty? || candidate_list.empty?

            match = candidate_list.filter_map do |candidate|
              overlap_tolerance_slab_match(candidate, point_list)
            end.min_by do |row|
              [
                row.fetch(:thickness),
                -row.fetch(:overlap_area),
                row.fetch(:candidate_index)
              ]
            end
            return intersection unless match

            raw_volume = intersection[:volume].to_f
            intersection.merge(
              status: :not_reproduced,
              reason: 'REPRODUCED_INTERSECTION_WITHIN_OVERLAP_TOLERANCE',
              volume: 0.0,
              raw_reproduced_volume: raw_volume,
              overlap_tolerance_gate: {
                applied: true,
                tolerance_in: @tolerance.to_f,
                tolerance_mm: @tolerance.to_f * 25.4,
                measured_thickness_in: match.fetch(:thickness),
                measured_thickness_mm: match.fetch(:thickness) * 25.4,
                candidate_penetration_depth_in:
                  match.fetch(:penetration_depth),
                candidate_penetration_depth_mm:
                  match.fetch(:penetration_depth) * 25.4,
                candidate_overlap_area_in2: match.fetch(:overlap_area),
                candidate_overlap_area_mm2:
                  match.fetch(:overlap_area) * 25.4 * 25.4,
                candidate_index: match.fetch(:candidate_index),
                point_count: point_list.length,
                raw_reproduced_volume_in3: raw_volume,
                raw_reproduced_volume_mm3:
                  raw_volume * 25.4 * 25.4 * 25.4
              }
            )
          end

          def overlap_tolerance_slab_match(candidate, points)
            normal = candidate[:normal]
            plane1 = candidate[:plane1]
            plane2 = candidate[:plane2]
            return nil unless normal && !plane1.nil? && !plane2.nil?

            nx = normal.x.to_f
            ny = normal.y.to_f
            nz = normal.z.to_f
            magnitude = Math.sqrt((nx * nx) + (ny * ny) + (nz * nz))
            return nil if magnitude <= 1.0e-30

            unit = [nx / magnitude, ny / magnitude, nz / magnitude]
            slab1 = plane1.to_f / magnitude
            slab2 = plane2.to_f / magnitude
            slab_min, slab_max = [slab1, slab2].minmax
            penetration_depth = candidate[:penetration_depth].to_f
            return nil if penetration_depth >
                          @tolerance.to_f + overlap_tolerance_numeric_epsilon

            projections = points.map do |point|
              (unit[0] * point.x.to_f) +
                (unit[1] * point.y.to_f) +
                (unit[2] * point.z.to_f)
            end
            return nil if projections.empty?

            epsilon = overlap_tolerance_numeric_epsilon
            return nil unless projections.all? do |value|
              value >= slab_min - epsilon && value <= slab_max + epsilon
            end

            thickness = projections.max - projections.min
            return nil if thickness > @tolerance.to_f + epsilon

            {
              candidate_index: candidate[:face1_index].to_i * 1_000_000 +
                candidate[:face2_index].to_i,
              thickness: thickness,
              penetration_depth: penetration_depth,
              overlap_area: candidate[:overlap_area].to_f
            }
          rescue StandardError
            nil
          end

          def overlap_tolerance_numeric_epsilon
            [@tolerance.to_f.abs * 1.0e-6, 1.0e-10].max
          end
        end

        # Applies the extension's explicit overlap tolerance to the unchanged
        # full-Solid rechecker. This is a prepend wrapper rather than an alias so
        # it composes safely with existing diagnostic prepend modules.
        module Val3dityExplicitOverlapToleranceBasePatch
          include Val3dityExplicitOverlapToleranceHelpers

          private

          def cache_intersection_overlay_geometry(result, cell_ids, volume)
            capture_overlap_tolerance_intersection_points(result, cell_ids)
            super
          end

          def model_solid_intersection_for_pair(
            group1,
            group2,
            cell_id1,
            cell_id2
          )
            key = pair_key(cell_id1, cell_id2)
            overlap_tolerance_point_cache.delete(key)
            result = super
            apply_explicit_overlap_tolerance_to_pair_result(
              result,
              group1,
              group2,
              key
            )
          ensure
            overlap_tolerance_point_cache.delete(key) if defined?(key) && key
          end
        end

        # Rechecker defines its own pair method above the base class. Wrap that
        # method independently, again with prepend, so direct-v3 and fallback
        # results receive the same policy without alias/super recursion.
        module Val3dityExplicitOverlapToleranceV3Patch
          include Val3dityExplicitOverlapToleranceHelpers

          private

          def model_solid_intersection_for_pair(
            group1,
            group2,
            cell_id1,
            cell_id2
          )
            key = pair_key(cell_id1, cell_id2)
            overlap_tolerance_point_cache.delete(key)
            result = super
            apply_explicit_overlap_tolerance_to_pair_result(
              result,
              group1,
              group2,
              key
            )
          ensure
            overlap_tolerance_point_cache.delete(key) if defined?(key) && key
          end
        end

        module Val3dityRecheckV3PositiveSafetyPatch
          private

          # The clipped proxy is a fast negative recheck. Empty results can be
          # accepted directly, while positive or non-solid results are delegated
          # to the unchanged full-Solid path for final classification.
          def direct_proxy_intersection(
            source,
            target,
            cell_ids,
            geometry,
            record
          )
            result = super
            return result unless result.is_a?(Hash)
            return result if result[:fallback]

            case result[:status].to_s
            when 'non_solid'
              record['non_solid_safety_gate'] = {
                'applied' => true,
                'proxy_status' => result[:status].to_s,
                'proxy_reason' => result[:reason].to_s,
                'proxy_volume_in3' => result[:volume],
                'proxy_component_count' => result[:component_count],
                'proxy_face_count' => result[:face_count],
                'proxy_edge_count' => result[:edge_count],
                'proxy_boundary_edge_count' => result[:boundary_edge_count],
                'proxy_nonmanifold_edge_count' =>
                  result[:nonmanifold_edge_count]
              }
              fallback_result('target_boolean_non_solid')
            when 'reproduced'
              record['positive_result_confirmation_gate'] = {
                'applied' => true,
                'proxy_status' => result[:status].to_s,
                'proxy_reason' => result[:reason].to_s,
                'proxy_volume_in3' => result[:volume],
                'proxy_component_count' => result[:component_count],
                'proxy_face_count' => result[:face_count],
                'proxy_edge_count' => result[:edge_count],
                'proxy_boundary_edge_count' => result[:boundary_edge_count],
                'proxy_nonmanifold_edge_count' =>
                  result[:nonmanifold_edge_count]
              }
              fallback_result(
                'target_boolean_reproduced_requires_original_confirmation'
              )
            else
              result
            end
          end
        end

        base_rechecker = Val3dityOverlapGeometryRechecker
        base_patch = Val3dityExplicitOverlapToleranceBasePatch
        base_rechecker.prepend(base_patch) unless
          base_rechecker.ancestors.include?(base_patch)

        v3_rechecker = Val3dityRecheckV3MeshProxy::Rechecker
        v3_tolerance_patch = Val3dityExplicitOverlapToleranceV3Patch
        v3_positive_patch = Val3dityRecheckV3PositiveSafetyPatch
        v3_rechecker.prepend(v3_tolerance_patch) unless
          v3_rechecker.ancestors.include?(v3_tolerance_patch)
        v3_rechecker.prepend(v3_positive_patch) unless
          v3_rechecker.ancestors.include?(v3_positive_patch)

        module Val3dityRecheckV3MeshProxy
          class << self
            def non_solid_fallback_enabled?
              true
            end

            def positive_result_confirmation_enabled?
              true
            end

            def explicit_overlap_tolerance_enabled?
              true
            end
          end
        end
      end
    end
  end
end
