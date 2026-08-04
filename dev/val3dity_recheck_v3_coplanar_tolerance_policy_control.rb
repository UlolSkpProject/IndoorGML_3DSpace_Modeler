# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_coplanar_complexity_control'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Test-harness bridge for the explicit production overlap-tolerance gate.
        # The existing control harness intentionally disables overlay caching; this
        # bridge still captures temporary Boolean result vertices without writing
        # any overlay or modifying the model/report.
        module Val3dityRecheckV3ToleranceCaptureHarness
          private

          def cache_intersection_overlay_geometry(result, cell_ids, _volume)
            capture_overlap_tolerance_intersection_points(result, cell_ids)
            false
          end
        end

        [
          Val3dityRecheckV3ControlGeometry::OriginalHarness,
          Val3dityRecheckV3ControlGeometry::V3Harness
        ].each do |klass|
          klass.prepend(Val3dityRecheckV3ToleranceCaptureHarness) unless
            klass.ancestors.include?(Val3dityRecheckV3ToleranceCaptureHarness)
        end

        module Val3dityRecheckV3CoplanarComplexityControl
          class << self
            unless private_method_defined?(:normalize_intersection_without_tolerance_diagnostic)
              alias_method :normalize_intersection_without_tolerance_diagnostic,
                           :normalize_intersection
            end

            private

            def normalize_intersection(result)
              normalized =
                normalize_intersection_without_tolerance_diagnostic(result)
              row = result.is_a?(Hash) ? result : {}
              gate = row[:overlap_tolerance_gate]
              raw_volume = row[:raw_reproduced_volume]

              normalized.merge(
                'raw_reproduced_volume_in3' => raw_volume,
                'raw_reproduced_volume_mm3' => raw_volume.nil? ? nil :
                  raw_volume.to_f * 25.4 * 25.4 * 25.4,
                'overlap_tolerance_gate' => gate
              )
            end
          end
        end
      end
    end
  end
end
