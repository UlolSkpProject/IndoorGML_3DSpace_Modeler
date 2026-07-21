# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        # Production strict-coplanar policy.
        #
        # The normalization grid is 0.001 mm. A 0.0001 mm plane-distance
        # tolerance is one tenth of a grid cell, so it remains conservative
        # while avoiding unstable plane splits caused by sub-grid numerical
        # deviations. This does not relax triangle-intersection or topology
        # validation.
        remove_const(:STRICT_COPLANAR_TOLERANCE_MM) if
          const_defined?(:STRICT_COPLANAR_TOLERANCE_MM, false)
        STRICT_COPLANAR_TOLERANCE_MM = 0.0001
      end
    end
  end
end
