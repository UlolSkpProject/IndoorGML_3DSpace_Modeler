# frozen_string_literal: true

require_relative 'overlap_recheck/adaptive_routing'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Canonical extension-side 701/704 geometry rechecker.
        #
        # CellSpace pairs at or below the measured face-count threshold use the
        # native Full-Solid engine directly. More complex pairs use the clipped
        # source mesh, retaining Full-Solid as the conservative confirmation
        # engine for positive, non-solid, or reconstruction-inconclusive cases.
        class Val3dityOverlapGeometryRechecker <
          Val3dityClippedMeshRecheck::Rechecker
        end
      end
    end
  end
end
