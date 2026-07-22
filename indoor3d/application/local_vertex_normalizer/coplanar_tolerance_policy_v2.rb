# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        # Use one normalization-grid step for strict coplanar comparisons.
        # The broader COPLANAR_TOLERANCE_MM remains 0.01 mm.
        remove_const(:STRICT_COPLANAR_TOLERANCE_MM) if
          const_defined?(:STRICT_COPLANAR_TOLERANCE_MM, false)
        STRICT_COPLANAR_TOLERANCE_MM = 0.001
      end
    end
  end
end
