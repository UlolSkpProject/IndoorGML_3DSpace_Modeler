# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class Rechecker
            private

            # Dev-path correction: `super` inside original_fallback would search
            # for a superclass implementation named original_fallback. The
            # intended target is the parent implementation of
            # model_solid_intersection_for_pair.
            def original_fallback(record, group1, group2, cell_id1, cell_id2, reason, started)
              fallback_started = clock
              base_method = Val3dityOverlapGeometryRechecker.instance_method(
                :model_solid_intersection_for_pair
              )
              result = base_method.bind(self).call(
                group1, group2, cell_id1, cell_id2
              )
              record['path'] = 'original_full_recheck_fallback'
              record['fallback_reason'] = reason.to_s
              record['fallback_elapsed_ms'] = elapsed_ms(fallback_started)
              record['intersection_status'] = result[:status].to_s if result.is_a?(Hash)
              record['intersection_reason'] = result[:reason].to_s if
                result.is_a?(Hash) && result[:reason]
              record['intersection_volume_in3'] = result[:volume] if
                result.is_a?(Hash) && result.key?(:volume)
              record['intersection_component_count'] = result[:component_count] if
                result.is_a?(Hash) && result.key?(:component_count)
              record['total_elapsed_ms'] = elapsed_ms(started)
              store_record(record)
              result
            end
          end
        end
      end
    end
  end
end
