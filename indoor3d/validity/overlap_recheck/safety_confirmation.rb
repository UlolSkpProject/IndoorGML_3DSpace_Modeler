# frozen_string_literal: true

require_relative 'boundary_global_edge_support'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityClippedMeshRecheck
          module SafetyConfirmation
            private

            # The clipped mesh is authoritative for confirmed empty results.
            # Positive or non-solid proxy results are delegated to the internal
            # full-geometry engine so previously successful kept decisions cannot
            # be lost through proxy reconstruction artifacts.
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
                record['non_solid_safety_gate'] = safety_gate_record(result)
                fallback_result('proxy_non_solid_requires_full_confirmation')
              when 'reproduced'
                record['positive_result_confirmation_gate'] =
                  safety_gate_record(result)
                fallback_result('proxy_positive_requires_full_confirmation')
              else
                result
              end
            end

            def safety_gate_record(result)
              {
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
            end
          end

          Rechecker.prepend(SafetyConfirmation) unless
            Rechecker.ancestors.include?(SafetyConfirmation)

          class << self
            def full_confirmation_enabled?
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
