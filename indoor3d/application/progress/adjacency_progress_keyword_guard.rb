# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module CellSpaceProgressContext
          THREAD_KEY = :ulol_indoor3d_cell_space_progress_session

          module_function

          def current
            Thread.current[THREAD_KEY]
          end

          def with(progress)
            previous = Thread.current[THREAD_KEY]
            Thread.current[THREAD_KEY] = progress
            yield
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end

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

        # Never forward :progress through TopologyCoordinator. A stale module left
        # by DevLoader may try to add it again, so the visible context is cleared
        # while the original topology method runs.
        module TopologyCoordinatorProgressKeywordGuard
          def synchronize_all(**kwargs)
            filtered = kwargs.dup
            explicit_sink = filtered.delete(:progress)
            sink = explicit_sink || AdjacencyProgressContext.current
            AdjacencyProgressExecutionContext.with(sink) do
              AdjacencyProgressContext.with(nil) { super(**filtered) }
            end
          end

          def synchronize_within(cell_spaces, **kwargs)
            filtered = kwargs.dup
            explicit_sink = filtered.delete(:progress)
            sink = explicit_sink || AdjacencyProgressContext.current
            AdjacencyProgressExecutionContext.with(sink) do
              AdjacencyProgressContext.with(nil) { super(cell_spaces, **filtered) }
            end
          end
        end

        # AdjacencyService owns the detailed stage events. The sink is injected
        # only into its private helpers; no public topology/material call receives
        # a new keyword. While a progress sink is active every logical item emits
        # an update instead of using the default 250-item checkpoint.
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

          def progress_checkpoint?(completed, total)
            return super unless active_progress_sink?

            completed.to_i.positive? && completed.to_i <= total.to_i
          end

          def active_progress_sink?
            !effective_progress_sink(nil).nil?
          end

          def effective_progress_sink(progress)
            progress ||
              AdjacencyProgressExecutionContext.current ||
              AdjacencyProgressContext.current
          end
        end

        # The public IndoorModel conversion signature remains untouched. The
        # progress session is injected only after the existing service is built.
        module IndoorModelCellSpaceProgressContextInjection
          private

          def build_batch_conversion_service(*arguments, **keywords)
            service = super
            progress = CellSpaceProgressContext.current
            if progress && service.respond_to?(:production_progress=)
              service.production_progress = progress
            end
            service
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

      if defined?(IndoorModel)
        IndoorModel.prepend(
          ProductionProgress::IndoorModelCellSpaceProgressContextInjection
        ) unless IndoorModel.ancestors.include?(
          ProductionProgress::IndoorModelCellSpaceProgressContextInjection
        )
      end
    end
  end
end
