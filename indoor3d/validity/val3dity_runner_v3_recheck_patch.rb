# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Safety rollback for the experimental v3 clipped-mesh rechecker.
        #
        # Independent geometry verification found positive-volume intersections
        # in pairs that v3 classified as not reproduced. Keep the patch require in
        # core.rb for branch history and diagnostics, but do not load, alias, or
        # replace any production recheck method. Validation therefore uses the
        # original Val3dityOverlapGeometryRechecker exactly as before v3 wiring.
        module Val3dityV3Runtime
          ROLLBACK_REASON =
            'independent verification reproduced positive-volume 701 overlaps'

          class << self
            def enabled?
              false
            end

            def available?
              false
            end

            def load_error
              nil
            end
          end
        end

        class Val3dityRunner
          class << self
            def v3_overlap_recheck_enabled?
              false
            end

            def v3_overlap_recheck_load_error
              nil
            end

            def v3_overlap_recheck_rollback_reason
              Val3dityV3Runtime::ROLLBACK_REASON
            end
          end
        end

        IndoorCore::Logger.puts(
          '[IndoorGML] val3dity 701/704 recheck mode: original rechecker; ' \
          'experimental v3 disabled after independent geometry verification failure'
        )
      end
    end
  end
end
