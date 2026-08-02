# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module AdjacencyProgressContext
          class << self
            attr_accessor :current_value
          end

          def self.current
            current_value
          end

          def self.with(value)
            previous = current_value
            self.current_value = value
            yield
          ensure
            self.current_value = previous
          end
        end

        # Simulates the older integration that blindly forwards :progress.
        module TopologyCoordinatorProgressIntegration
          def synchronize_all(**kwargs)
            sink = AdjacencyProgressContext.current
            kwargs = kwargs.merge(progress: sink) if sink && !kwargs.key?(:progress)
            super(**kwargs)
          end

          def synchronize_within(cell_spaces, **kwargs)
            sink = AdjacencyProgressContext.current
            kwargs = kwargs.merge(progress: sink) if sink && !kwargs.key?(:progress)
            super(cell_spaces, **kwargs)
          end
        end

        class AdjacencyProgressSink
          def call(_event)
            true
          end

          private

          def log_error(_context, _error); end
        end
      end

      class TopologyCoordinator
        prepend ProductionProgress::TopologyCoordinatorProgressIntegration

        def initialize(adjacency_service)
          @adjacency_service = adjacency_service
        end

        def synchronize_all(**kwargs)
          @adjacency_service.synchronize_all(**kwargs)
        end

        def synchronize_within(cell_spaces, **kwargs)
          @adjacency_service.synchronize_within(cell_spaces, **kwargs)
        end
      end

      class BulkCellSpaceConversionService
        def initialize
          @converter = proc {}
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
        class ProgressKeywordCompatibilityTest < Minitest::Test
          class LegacyAdjacency
            attr_reader :calls

            def initialize
              @calls = 0
            end

            def synchronize_all
              @calls += 1
              :legacy_ok
            end

            def synchronize_within(cell_spaces)
              @calls += cell_spaces.length
              :legacy_within_ok
            end
          end

          class ProgressAdjacency
            attr_reader :received_progress

            def synchronize_all(progress: nil)
              @received_progress = progress
              :progress_ok
            end

            def synchronize_within(_cell_spaces, progress: nil)
              @received_progress = progress
              :progress_within_ok
            end
          end

          def setup
            AdjacencyProgressContext.current_value = Object.new
          end

          def teardown
            AdjacencyProgressContext.current_value = nil
          end

          def test_progress_keyword_is_not_forwarded_to_legacy_service
            service = LegacyAdjacency.new
            coordinator = IndoorCore::TopologyCoordinator.new(service)

            assert_equal :legacy_ok, coordinator.synchronize_all
            assert_equal :legacy_within_ok, coordinator.synchronize_within([:a, :b])
            assert_equal 3, service.calls
          end

          def test_progress_keyword_is_forwarded_when_supported
            service = ProgressAdjacency.new
            coordinator = IndoorCore::TopologyCoordinator.new(service)

            assert_equal :progress_ok, coordinator.synchronize_all
            assert_same AdjacencyProgressContext.current_value, service.received_progress
            assert_equal :progress_within_ok, coordinator.synchronize_within([:a])
            assert_same AdjacencyProgressContext.current_value, service.received_progress
          end

          def test_outer_compatibility_remains_effective_after_old_module_method_redefinition
            ProductionProgress::TopologyCoordinatorProgressIntegration.module_eval do
              define_method(:synchronize_all) do |**kwargs|
                sink = ProductionProgress::AdjacencyProgressContext.current
                kwargs = kwargs.merge(progress: sink) if sink
                super(**kwargs)
              end
            end

            service = LegacyAdjacency.new
            coordinator = IndoorCore::TopologyCoordinator.new(service)

            assert_equal :legacy_ok, coordinator.synchronize_all
            assert_equal 1, service.calls
          end
        end
      end
    end
  end
end
