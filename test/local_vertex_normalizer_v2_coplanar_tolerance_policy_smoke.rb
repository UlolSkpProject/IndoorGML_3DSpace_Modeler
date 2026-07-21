# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        STRICT_COPLANAR_TOLERANCE_MM = 0.00001 unless
          const_defined?(:STRICT_COPLANAR_TOLERANCE_MM, false)
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/coplanar_tolerance_policy_v2'

klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
unless klass::STRICT_COPLANAR_TOLERANCE_MM == 0.0001
  raise "effective strict coplanar tolerance is #{klass::STRICT_COPLANAR_TOLERANCE_MM.inspect}"
end

puts 'LocalVertexNormalizer coplanar tolerance policy smoke test: OK'
