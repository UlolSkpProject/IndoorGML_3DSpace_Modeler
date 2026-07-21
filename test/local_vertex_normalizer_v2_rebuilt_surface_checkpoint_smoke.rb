# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        class Error < StandardError; end
        class ReconstructionError < Error; end

        attr_accessor :surface_equivalent

        def initialize
          @surface_equivalent = true
        end

        private

        def normalized_triangle_snapshot(_entities, duplicate_diagnostics:)
          duplicate_diagnostics[:duplicate_count] ||= 0
          duplicate_diagnostics[:samples] ||= []
          []
        end

        def verify_triangle_rebuild!(expected, actual)
          return true if expected == actual

          raise ReconstructionError, 'triangle keys differ'
        end

        def verify_normalized_surface_equivalence!(_expected, _actual)
          raise Error, 'patch boundaries differ' unless @surface_equivalent

          { equivalent: true }
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/rebuilt_surface_checkpoint_v2'

klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
entities = Object.new
expected = [{ points: [:a, :b, :c] }]
actual = [{ points: [:a, :c, :d] }]

normalizer = klass.new
diagnostics = {}
normalizer.send(
  :normalized_triangle_snapshot,
  entities,
  duplicate_diagnostics: diagnostics
)
normalizer.surface_equivalent = true
unless normalizer.send(:verify_triangle_rebuild!, expected, actual)
  raise 'surface-equivalent retriangulation was rejected'
end
checkpoint = normalizer.instance_variable_get(:@validated_rebuild_surface_checkpoint)
unless checkpoint[:surface_equivalent] == true &&
       checkpoint[:exact_triangle_match] == false &&
       checkpoint.dig(:surface_equivalence, :strategy) ==
         :equivalent_surface_retriangulation
  raise "unexpected checkpoint: #{checkpoint.inspect}"
end

normalizer = klass.new
diagnostics = {}
normalizer.send(
  :normalized_triangle_snapshot,
  entities,
  duplicate_diagnostics: diagnostics
)
normalizer.surface_equivalent = false
begin
  normalizer.send(:verify_triangle_rebuild!, expected, actual)
  raise 'different rebuilt surface passed the hard checkpoint'
rescue klass::RebuiltSurfaceCheckpointError => error
  unless error.message.include?('failed before post-processing') &&
         error.message.include?('patch boundaries differ')
    raise "unexpected hard-gate error: #{error.message}"
  end
end

normalizer = klass.new
diagnostics = { duplicate_count: 2, samples: [:duplicate] }
normalizer.send(
  :normalized_triangle_snapshot,
  entities,
  duplicate_diagnostics: diagnostics
)
begin
  normalizer.send(:verify_triangle_rebuild!, expected, expected)
  raise 'duplicate rebuilt faces passed the hard checkpoint'
rescue klass::RebuiltSurfaceCheckpointError => error
  raise error unless error.message.include?('duplicate triangle faces')
end

puts 'LocalVertexNormalizer rebuilt surface checkpoint smoke test: OK'
