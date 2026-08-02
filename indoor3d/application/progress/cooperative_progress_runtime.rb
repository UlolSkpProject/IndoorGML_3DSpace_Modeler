# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module CooperativeYieldContext
          THREAD_KEY = :ulol_indoor3d_cooperative_yield

          module_function

          def current
            Thread.current[THREAD_KEY]
          end

          def with(callback)
            previous = Thread.current[THREAD_KEY]
            Thread.current[THREAD_KEY] = callback
            yield
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end

        # This wrapper remains outside the original progress integration. When the
        # active adjacency implementation does not accept :progress, it suppresses
        # the inherited context while delegating so an older module cannot re-add
        # the unsupported keyword during a later DevLoader reload.
        module TopologyCoordinatorProgressCompatibility
          def synchronize_all(**kwargs)
            if adjacency_method_accepts_progress?(:synchronize_all)
              super(**kwargs)
            else
              filtered = kwargs.dup
              filtered.delete(:progress)
              AdjacencyProgressContext.with(nil) { super(**filtered) }
            end
          end

          def synchronize_within(cell_spaces, **kwargs)
            if adjacency_method_accepts_progress?(:synchronize_within)
              super(cell_spaces, **kwargs)
            else
              filtered = kwargs.dup
              filtered.delete(:progress)
              AdjacencyProgressContext.with(nil) { super(cell_spaces, **filtered) }
            end
          end

          private

          def adjacency_method_accepts_progress?(method_name)
            service = instance_variable_get(:@adjacency_service)
            return false unless service&.respond_to?(method_name)

            service.method(method_name).parameters.any? do |kind, name|
              kind == :keyrest || ((kind == :key || kind == :keyreq) && name == :progress)
            end
          rescue StandardError
            false
          end
        end

        module AdjacencyProgressSinkCooperativeYield
          def call(event)
            result = super
            event_name = event.respond_to?(:[]) ? event[:event]&.to_sym : nil
            cooperative_yield if event_name == :stage_start || event_name == :stage_progress
            result
          end

          private

          def cooperative_yield
            callback = CooperativeYieldContext.current
            callback.call if callback&.respond_to?(:call)
          rescue StandardError => e
            log_error('cooperative yield', e)
            false
          end
        end

        module BulkCellSpaceConversionCooperativeYield
          def cooperative_yield=(callback)
            @cooperative_yield = callback
            install_cooperative_converter_wrapper
            callback
          end

          private

          def install_cooperative_converter_wrapper
            return if @cooperative_converter_wrapper_installed

            @cooperative_converter_wrapper_installed = true
            original = @converter
            @converter = proc do |source, cell_type, category_code, storey|
              result = if original.respond_to?(:arity) && original.arity == 3
                         original.call(source, cell_type, category_code)
                       else
                         original.call(source, cell_type, category_code, storey)
                       end
              callback = @cooperative_yield
              callback.call if callback&.respond_to?(:call)
              result
            end
          end
        end

        module IndoorModelCellSpaceCooperativeYield
          def convert_cell_space_jobs_bulk(
            jobs,
            fallback_target:,
            original_active_path:,
            preserve_source: nil,
            operation_name: 'Convert Solid Groups to CellSpace',
            activate_root_context: true,
            progress: nil,
            yield_control: nil
          )
            previous_yield = @production_cell_space_yield_control
            @production_cell_space_yield_control = yield_control
            CooperativeYieldContext.with(yield_control) do
              super(
                jobs,
                fallback_target: fallback_target,
                original_active_path: original_active_path,
                preserve_source: preserve_source,
                operation_name: operation_name,
                activate_root_context: activate_root_context,
                progress: progress
              )
            end
          ensure
            @production_cell_space_yield_control = previous_yield
          end

          private

          def build_batch_conversion_service(*arguments, **keywords)
            service = super
            callback = @production_cell_space_yield_control
            if callback && service.respond_to?(:cooperative_yield=)
              service.cooperative_yield = callback
            end
            service
          end
        end
      end

      if defined?(TopologyCoordinator)
        TopologyCoordinator.prepend(
          ProductionProgress::TopologyCoordinatorProgressCompatibility
        ) unless TopologyCoordinator.ancestors.include?(
          ProductionProgress::TopologyCoordinatorProgressCompatibility
        )
      end

      if defined?(ProductionProgress::AdjacencyProgressSink)
        ProductionProgress::AdjacencyProgressSink.prepend(
          ProductionProgress::AdjacencyProgressSinkCooperativeYield
        ) unless ProductionProgress::AdjacencyProgressSink.ancestors.include?(
          ProductionProgress::AdjacencyProgressSinkCooperativeYield
        )
      end

      BulkCellSpaceConversionService.prepend(
        ProductionProgress::BulkCellSpaceConversionCooperativeYield
      ) unless BulkCellSpaceConversionService.ancestors.include?(
        ProductionProgress::BulkCellSpaceConversionCooperativeYield
      )

      IndoorModel.prepend(
        ProductionProgress::IndoorModelCellSpaceCooperativeYield
      ) unless IndoorModel.ancestors.include?(
        ProductionProgress::IndoorModelCellSpaceCooperativeYield
      )
    end
  end
end
