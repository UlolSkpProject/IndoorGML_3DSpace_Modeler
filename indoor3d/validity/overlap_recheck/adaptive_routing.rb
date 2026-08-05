# frozen_string_literal: true

require_relative 'safety_confirmation'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityClippedMeshRecheck
          # Routes low-complexity CellSpace pairs directly through the native
          # Full-Solid Boolean engine. The clipped-mesh pipeline remains the
          # default for pairs above the measured complexity threshold.
          module AdaptiveRouting
            SIMPLE_SOLID_FACE_THRESHOLD = 300
            DIRECT_FULL_PATH = 'full_geometry_direct_simple'

            private

            def model_solid_intersection_for_pair(
              group1, group2, cell_id1, cell_id2
            )
              face_counts = adaptive_routing_face_counts(cell_id1, cell_id2)
              return super unless adaptive_full_geometry_route?(face_counts)

              direct_full_geometry_intersection(
                group1,
                group2,
                cell_id1,
                cell_id2,
                face_counts
              )
            end

            def adaptive_routing_face_counts(cell_id1, cell_id2)
              [cell_id1, cell_id2].map do |cell_id|
                geometry = model_cell_geometry(cell_id)
                return nil unless geometry[:status] == :ok

                Array(geometry[:faces]).length
              end
            rescue StandardError
              nil
            end

            def adaptive_full_geometry_route?(face_counts)
              Array(face_counts).length == 2 &&
                face_counts.all?(&:positive?) &&
                face_counts.max <= SIMPLE_SOLID_FACE_THRESHOLD
            end

            def direct_full_geometry_intersection(
              group1,
              group2,
              cell_id1,
              cell_id2,
              face_counts
            )
              started = clock
              cells = [cell_id1.to_s, cell_id2.to_s]
              record = {
                'cells' => cells,
                'mode' => MODE,
                'routing_mode' => 'face_count_adaptive',
                'path' => DIRECT_FULL_PATH,
                'fallback_reason' => nil,
                'simple_solid_face_threshold' => SIMPLE_SOLID_FACE_THRESHOLD,
                'input_face_counts' => face_counts,
                'max_input_face_count' => face_counts.max
              }

              full_started = clock
              method = Val3dityFullIntersectionRechecker.instance_method(
                :model_solid_intersection_for_pair
              )
              result = method.bind(self).call(
                group1, group2, cell_id1, cell_id2
              )
              record['direct_full_elapsed_ms'] = elapsed_ms(full_started)
              record_adaptive_result(record, result, started)
              result
            end

            def record_adaptive_result(record, result, started)
              if result.is_a?(Hash)
                record['intersection_status'] = result[:status].to_s
                record['intersection_reason'] = result[:reason].to_s if
                  result[:reason]
                record['intersection_volume_in3'] = result[:volume] if
                  result.key?(:volume)
                record['intersection_component_count'] =
                  result[:component_count] if result.key?(:component_count)
              end
              record['total_elapsed_ms'] = elapsed_ms(started)
              store_record(record)
            end
          end

          Rechecker.prepend(AdaptiveRouting) unless
            Rechecker.ancestors.include?(AdaptiveRouting)

          class << self
            def simple_solid_face_threshold
              AdaptiveRouting::SIMPLE_SOLID_FACE_THRESHOLD
            end
          end
        end
      end
    end
  end
end
