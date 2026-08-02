# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module AdjacencyProgressContext
          def self.current
            nil
          end
        end

        module TopologyCoordinatorProgressIntegration; end
      end

      class BulkCellSpaceConversionService
        def initialize(converter)
          @converter = converter
        end

        def execute(*arguments)
          @converter.call(*arguments)
        end
      end

      class IndoorModel; end
    end
  end
end

require_relative '../indoor3d/application/progress/cooperative_progress_runtime'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class CooperativeConversionYieldTest < Minitest::Test
          def test_successful_conversion_yields_after_result
            events = []
            service = BulkCellSpaceConversionService.new(
              proc do |source, type, category, storey|
                events << [:converted, source, type, category, storey]
                :converted_result
              end
            )
            service.cooperative_yield = proc { events << :yielded }

            result = service.execute(:source, :general, nil, 'F01')

            assert_equal :converted_result, result
            assert_equal [
              [:converted, :source, :general, nil, 'F01'],
              :yielded
            ], events
          end

          def test_failed_conversion_does_not_yield_before_rollback
            yielded = false
            service = BulkCellSpaceConversionService.new(
              proc { |_source, _type, _category, _storey| raise 'conversion failed' }
            )
            service.cooperative_yield = proc { yielded = true }

            error = assert_raises(RuntimeError) do
              service.execute(:source, :general, nil, 'F01')
            end

            assert_equal 'conversion failed', error.message
            refute yielded
          end
        end
      end
    end
  end
end
