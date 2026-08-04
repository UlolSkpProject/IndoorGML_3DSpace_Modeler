# frozen_string_literal: true

require_relative 'overlap_recheck/safety_confirmation'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Canonical extension-side 701/704 geometry rechecker.
        #
        # The primary path uses a clipped source mesh. Full-Solid Boolean is
        # available only through the inherited private confirmation engine for
        # positive, non-solid, or reconstruction-inconclusive cases.
        class Val3dityOverlapGeometryRechecker <
          Val3dityClippedMeshRecheck::Rechecker
        end
      end
    end
  end
end
