# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module AdjacencyProgressExecutionContext
          THREAD_KEY = :ulol_indoor3d_adjacency_progress_execution_sink

          module_function

          def current
            Thread.current[THREAD_KEY]
          end

          def with(sink)
            previous = Thread.current[THREAD_KEY]
            Thread.current[THREAD_KEY] = sink
            yield
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end

        # Prevent every outer topology layer, including a stale DevLoader-prepended
        # module, from forwarding the unsupported :progress keyword. The sink is
        # preserved separately and consumed only inside AdjacencyService.
        module TopologyCoordinatorProgressKeywordGuard
          def synchronize_all(**kwargs)
            filtered = kwargs.dup
            sink = AdjacencyProgressContext.current || filtered.delete(:progress)
            filtered.delete(:progress)
            AdjacencyProgressExecutionContext.with(sink) do
              AdjacencyProgressContext.with(nil) { super(**filtered) }
            end
          end

          def synchronize_within(cell_spaces, **kwargs)
            filtered = kwargs.dup
            sink = AdjacencyProgressContext.current || filtered.delete(:progress)
            filtered.delete(:progress)
            AdjacencyProgressExecutionContext.with(sink) do
              AdjacencyProgressContext.with(nil) { super(cell_spaces, **filtered) }
            end
          end
        end

        # AdjacencyService already owns the detailed stage hooks. Inject the sink
        # into those private hooks only; no public service call receives :progress.
        module AdjacencyServiceProgressContextBridge
          private

          def adjacency_snapshot_entries(*arguments, progress: nil)
            super(*arguments, progress: effective_progress_sink(progress))
          end

          def compute_pair_results(entries, tolerance:, progress: nil)
            super(
              entries,
              tolerance: tolerance,
              progress: effective_progress_sink(progress)
            )
          end

          def apply_pair_results(
            entries,
            pair_results,
            transition_builder:,
            transition_eraser:,
            stale_pair_keys: nil,
            progress: nil
          )
            super(
              entries,
              pair_results,
              transition_builder: transition_builder,
              transition_eraser: transition_eraser,
              stale_pair_keys: stale_pair_keys,
              progress: effective_progress_sink(progress)
            )
          end

          def effective_progress_sink(progress)
            progress || AdjacencyProgressExecutionContext.current
          end
        end
      end

      if defined?(TopologyCoordinator)
        TopologyCoordinator.prepend(
          ProductionProgress::TopologyCoordinatorProgressKeywordGuard
        ) unless TopologyCoordinator.ancestors.include?(
          ProductionProgress::TopologyCoordinatorProgressKeywordGuard
        )
      end

      if defined?(AdjacencyService)
        AdjacencyService.prepend(
          ProductionProgress::AdjacencyServiceProgressContextBridge
        ) unless AdjacencyService.ancestors.include?(
          ProductionProgress::AdjacencyServiceProgressContextBridge
        )
      end
    end
  end
end
