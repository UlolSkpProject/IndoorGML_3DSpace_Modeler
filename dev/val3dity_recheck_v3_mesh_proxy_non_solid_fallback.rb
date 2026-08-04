# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_boundary_dp_global_edge_support_repair'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class Rechecker
            unless private_method_defined?(:direct_proxy_intersection_without_non_solid_fallback)
              alias_method :direct_proxy_intersection_without_non_solid_fallback,
                           :direct_proxy_intersection
            end

            private

            # Conservative final-Boolean safety gates.
            #
            # The clipped proxy is used as a fast negative recheck. A valid empty
            # result can therefore be accepted directly. Any result that claims a
            # positive volumetric intersection must be confirmed by the unchanged
            # original full-Solid recheck, because SketchUp can occasionally close
            # a small artifact shell around dense coplanar subdivisions. Likewise,
            # a non-solid result is incomplete and must fall back.
            #
            # This policy is geometry-agnostic:
            # - not_reproduced: accept the v3 negative result;
            # - non_solid: original full-recheck fallback;
            # - reproduced: original full-recheck confirmation;
            # - existing fallback requests: preserve unchanged.
            def direct_proxy_intersection(source, target, cell_ids, geometry, record)
              result = direct_proxy_intersection_without_non_solid_fallback(
                source,
                target,
                cell_ids,
                geometry,
                record
              )
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

          class << self
            def non_solid_fallback_enabled?
              true
            end

            def positive_result_confirmation_enabled?
              true
            end
          end
        end
      end
    end
  end
end
