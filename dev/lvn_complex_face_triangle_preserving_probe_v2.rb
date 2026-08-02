# frozen_string_literal: true

# Bootstrap the LocalVertexNormalizer constants referenced lexically by the
# prepend module in the Phase 5.5.2 probe. Ruby does not resolve unqualified
# constants through the class that receives a prepended module, so the original
# probe would mask the first validation exception with NameError and would later
# fail on TopologyChangedError or MM_PER_INCH for the same reason.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnComplexFaceTrianglePreservingProbe
        module Implementation
          Error = LocalVertexNormalizer::Error unless const_defined?(:Error, false)
          TopologyChangedError = LocalVertexNormalizer::TopologyChangedError unless
            const_defined?(:TopologyChangedError, false)
          MM_PER_INCH = LocalVertexNormalizer::MM_PER_INCH unless
            const_defined?(:MM_PER_INCH, false)
        end
      end
    end
  end
end

load File.expand_path('lvn_complex_face_triangle_preserving_probe.rb', __dir__)

nil
