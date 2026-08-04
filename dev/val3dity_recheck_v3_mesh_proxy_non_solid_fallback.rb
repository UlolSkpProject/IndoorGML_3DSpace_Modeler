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

            # Dev-only conservative safety gate.
            #
            # A non-solid result from SketchUp's final proxy-versus-target Boolean
            # is not a valid volumetric intersection result. Do not classify the
            # pair from that incomplete result; delegate the same pair to the
            # unchanged original full recheck instead.
            #
            # This rule is geometry-agnostic and changes only the non-solid result
            # path. Valid empty intersections, valid solid intersections, and all
            # existing pre-Boolean fallback paths remain untouched.
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
              return result unless result[:status].to_s == 'non_solid'

              record['non_solid_safety_gate'] = {
                'applied' => true,
                'proxy_status' => result[:status].to_s,
                'proxy_reason' => result[:reason].to_s,
                'proxy_volume_in3' => result[:volume],
                'proxy_component_count' => result[:component_count]
              }
              fallback_result('target_boolean_non_solid')
            end
          end

          class << self
            def non_solid_fallback_enabled?
              true
            end
          end
        end
      end
    end
  end
end
