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

        module TopologyCoordinatorProgressKeywordGuard
          def synchronize_all(**kwargs)
            filtered = kwargs.dup
            explicit_sink = filtered.delete(:progress)
            sink = AdjacencyProgressContext.current || explicit_sink
            AdjacencyProgressExecutionContext.with(sink) do
              AdjacencyProgressContext.with(nil) { super(**filtered) }
            end
          end

          def synchronize_within(cell_spaces, **kwargs)
            filtered = kwargs.dup
            explicit_sink = filtered.delete(:progress)
            sink = AdjacencyProgressContext.current || explicit_sink
            AdjacencyProgressExecutionContext.with(sink) do
              AdjacencyProgressContext.with(nil) { super(cell_spaces, **filtered) }
            end
          end
        end

        module AdjacencyServiceProgressContextBridge
          TARGET_PROGRESS_UPDATES_PER_STAGE = 100
          HIDDEN_OVERLAY_STAGES = %i[snapshot candidate_generation].freeze

          def synchronize_all(*arguments, **keywords)
            delegate_without_progress(arguments, keywords) { |args, filtered| super(*args, **filtered) }
          end

          def synchronize_within(*arguments, **keywords)
            delegate_without_progress(arguments, keywords) { |args, filtered| super(*args, **filtered) }
          end

          private

          def adjacency_snapshot_entries(*arguments, **keywords)
            delegate_without_progress(arguments, keywords) { |args, filtered| super(*args, **filtered) }
          end

          def compute_pair_results(entries, tolerance:, **keywords)
            delegate_without_progress([entries], keywords) do |args, filtered|
              super(*args, tolerance: tolerance, **filtered)
            end
          end

          def candidate_pair_indices(snapshots, tolerance, **keywords)
            delegate_without_progress([snapshots, tolerance], keywords) do |args, filtered|
              super(*args, **filtered)
            end
          end

          def compute_pair_chunk(snapshots, pair_indices, tolerance, **keywords)
            delegate_without_progress([snapshots, pair_indices, tolerance], keywords) do |args, filtered|
              super(*args, **filtered)
            end
          end

          def apply_pair_results(
            entries,
            pair_results,
            transition_builder:,
            transition_eraser:,
            stale_pair_keys: nil,
            **keywords
          )
            delegate_without_progress([entries, pair_results], keywords) do |args, filtered|
              super(
                *args,
                transition_builder: transition_builder,
                transition_eraser: transition_eraser,
                stale_pair_keys: stale_pair_keys,
                **filtered
              )
            end
          end

          def emit_stage_start(progress = nil, **payload)
            return false if hidden_overlay_stage?(payload[:stage])

            super(effective_progress_sink(progress), **payload)
          end

          def emit_stage_progress(progress = nil, **payload)
            return false if hidden_overlay_stage?(payload[:stage])

            super(effective_progress_sink(progress), **payload)
          end

          def emit_stage_finish(progress = nil, **payload)
            return false if hidden_overlay_stage?(payload[:stage])

            super(effective_progress_sink(progress), **payload)
          end

          def progress_checkpoint?(completed, total)
            return super unless active_progress_sink?

            completed = completed.to_i
            total = total.to_i
            return false if completed <= 0 || total <= 0
            return true if completed == 1 || completed >= total

            (completed % adaptive_progress_update_step(total)).zero?
          end

          def adaptive_progress_update_step(total)
            total = total.to_i
            if @adaptive_progress_total == total
              return @adaptive_progress_update_step
            end

            raw_step = [
              (total.to_f / TARGET_PROGRESS_UPDATES_PER_STAGE).ceil,
              1
            ].max
            @adaptive_progress_total = total
            @adaptive_progress_update_step = nice_progress_update_step(raw_step)
          end

          def nice_progress_update_step(raw_step)
            raw_step = [raw_step.to_i, 1].max
            magnitude = 1
            magnitude *= 10 while raw_step > magnitude * 10
            normalized = raw_step.fdiv(magnitude)

            factor = if normalized <= 1.0
                       1
                     elsif normalized <= 2.0
                       2
                     elsif normalized <= 5.0
                       5
                     else
                       10
                     end
            factor * magnitude
          end

          def hidden_overlay_stage?(stage)
            HIDDEN_OVERLAY_STAGES.include?(stage&.to_sym)
          end

          def delegate_without_progress(arguments, keywords)
            filtered = keywords.dup
            explicit_sink = filtered.delete(:progress)
            sink = effective_progress_sink(explicit_sink)
            AdjacencyProgressExecutionContext.with(sink) do
              yield(arguments, filtered)
            end
          end

          def active_progress_sink?
            !effective_progress_sink(nil).nil?
          end

          def effective_progress_sink(progress)
            AdjacencyProgressExecutionContext.current ||
              AdjacencyProgressContext.current ||
              progress
          end
        end

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

        # A successful bulk conversion commits before its active path is restored.
        # Keep that restoration inside the existing bulk observer-suppression guard
        # so onActivePathChanged cannot create a second attribute transaction.
        # Rollback and exception paths retain their original restore ordering.
        module BulkCellSpaceConversionActivePathRestoreGuard
          def initialize(*arguments, **keywords)
            super(*arguments, **keywords)
            install_guarded_active_path_restore
          end

          def call
            @production_active_path_restore_consumed = false
            @production_bulk_operation_outcome = nil
            super
          ensure
            @production_bulk_operation_outcome = nil
          end

          private

          def install_guarded_active_path_restore
            return if @production_active_path_restore_guard_installed
            return unless @apply_guards&.respond_to?(:call)
            return unless @operation_runner&.respond_to?(:call)
            return unless @restore_active_path&.respond_to?(:call)

            @production_active_path_restore_guard_installed = true
            original_apply_guards = @apply_guards
            original_operation_runner = @operation_runner
            original_restore_active_path = @restore_active_path

            @operation_runner = proc do |name, **options, &block|
              rollback_observed = false
              wrapped_options = options.dup
              rollback_if = wrapped_options[:rollback_if]
              if rollback_if&.respond_to?(:call)
                wrapped_options[:rollback_if] = proc do
                  rollback_observed = rollback_if.call == true
                end
              end

              result = original_operation_runner.call(name, **wrapped_options, &block)
              @production_bulk_operation_outcome = rollback_observed ? :rolled_back : :committed
              result
            rescue StandardError
              @production_bulk_operation_outcome = :failed
              raise
            end

            @apply_guards = proc do |&block|
              original_apply_guards.call do
                result = block.call
                if @production_bulk_operation_outcome == :committed
                  safely_restore_active_path(success: true)
                end
                result
              end
            end

            @restore_active_path = proc do
              restore_active_path_once(original_restore_active_path)
            end
          end

          def restore_active_path_once(callback)
            return true if @production_active_path_restore_consumed

            @production_active_path_restore_consumed = true
            callback.call
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

      if defined?(BulkCellSpaceConversionService)
        BulkCellSpaceConversionService.prepend(
          ProductionProgress::BulkCellSpaceConversionActivePathRestoreGuard
        ) unless BulkCellSpaceConversionService.ancestors.include?(
          ProductionProgress::BulkCellSpaceConversionActivePathRestoreGuard
        )
      end
    end
  end
end
