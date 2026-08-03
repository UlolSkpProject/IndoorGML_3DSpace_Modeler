# frozen_string_literal: true

# Dev-only compatibility launcher. The injected Implementation methods keep
# their lexical constant lookup, while the production constants live on
# LocalVertexNormalizer. Alias both constants before loading the original probe.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnCoplanarIncrementalTopologyProbe
        module Implementation
          MAX_COPLANAR_PASSES =
            LocalVertexNormalizer::MAX_COPLANAR_PASSES unless
              const_defined?(:MAX_COPLANAR_PASSES, false)

          DestructiveCoplanarCleanupError =
            LocalVertexNormalizer::DestructiveCoplanarCleanupError unless
              const_defined?(:DestructiveCoplanarCleanupError, false)
        end
      end
    end
  end
end

load File.join(__dir__, 'lvn_coplanar_incremental_topology_probe.rb')
