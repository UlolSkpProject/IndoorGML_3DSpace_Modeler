# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module AdjacencyProgressContext
          THREAD_KEY = :ulol_indoor3d_adjacency_progress_sink

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

        class AdjacencyProgressSink
          def initialize(progress, logger: IndoorCore::Logger)
            @progress = progress
            @logger = logger
            @stage_open = false
            @stage_name = nil
          end

          def mark_stage_open(name)
            @stage_open = true
            @stage_name = name.to_s
            true
          end

          def call(event)
            payload = event.to_h
            case payload[:event]&.to_sym
            when :stage_start
              start_stage(payload)
            when :stage_progress
              update_stage(payload)
            when :stage_finish
              finish_stage(payload)
            end
            true
          rescue StandardError => e
            log_error('event', e)
            false
          end

          def finish_open_stage(message: nil, telemetry: nil)
            return false unless @stage_open
            return false unless progress_active?

            @progress.finish_stage(
              message: message || "#{@stage_name} 완료",
              telemetry: telemetry
            )
            @stage_open = false
            @stage_name = nil
            true
          rescue StandardError => e
            log_error('finish open stage', e)
            @stage_open = false
            @stage_name = nil
            false
          end

          private

          def start_stage(payload)
            finish_open_stage
            return false unless progress_active?

            @progress.start_stage(
              payload[:name].to_s,
              total: payload[:total].to_i,
              message: payload[:message].to_s,
              cancellable: false,
              metadata: {
                source: :adjacency_service,
                stage: payload[:stage]
              }
            )
            mark_stage_open(payload[:name])
          end

          def update_stage(payload)
            return false unless @stage_open
            return false unless progress_active?

            @progress.update_stage(
              completed: payload[:completed].to_i,
              message: payload[:message].to_s,
              telemetry: payload[:telemetry]
            )
            true
          end

          def finish_stage(payload)
            return false unless @stage_open
            return false unless progress_active?

            @progress.finish_stage(
              message: payload[:message].to_s,
              telemetry: payload[:telemetry]
            )
            @stage_open = false
            @stage_name = nil
            true
          end

          def progress_active?
            @progress&.active? == true
          end

          def log_error(context, error)
            @logger.puts(
              "[IndoorGML] Adjacency progress #{context} failed: #{error.class}: #{error.message}"
            )
          rescue StandardError
            nil
          end
        end

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

        module BulkCellSpaceConversionProgressIntegration
          def production_progress=(progress)
            @production_progress = progress
            install_production_progress_callbacks
            progress
          end

          private

          def prepare_plan
            progress_start_stage(
              '사전검사/작업 준비',
              total: @jobs.length,
              message: "CellSpace 작업 준비: #{@jobs.length}개"
            )
            result = super
            progress_finish_stage(message: 'CellSpace 작업 준비 완료')
            result
          end

          def validate_plan_geometry(plan)
            progress_start_stage(
              '사전검사/형상 검증',
              total: plan.length,
              message: "CellSpace 형상 검증: #{plan.length}개"
            )
            result = super
            progress_finish_stage(message: 'CellSpace 형상 검증 완료')
            result
          end

          def validate_plan_targets(plan)
            progress_start_stage(
              '사전검사/대상 검증',
              total: plan.length,
              message: "CellSpace 대상 검증: #{plan.length}개"
            )
            result = super
            progress_finish_stage(message: 'CellSpace 대상 검증 완료')
            result
          end

          def apply_plan(plan)
            @production_progress_creation_total = plan.length
            @production_progress_creation_completed = 0
            @production_progress_creation_stage_open = true
            progress_start_stage(
              'CellSpace/State 생성',
              total: plan.length,
              message: "CellSpace/State 생성: 0 / #{plan.length}"
            )
            result = super
            finish_creation_progress_stage
            result
          rescue StandardError
            raise
          ensure
            finish_creation_progress_stage if @production_progress&.active?
          end

          def install_production_progress_callbacks
            return if @production_progress_callbacks_installed

            @production_progress_callbacks_installed = true
            wrap_converter_for_production_progress
            wrap_topology_sync_for_production_progress
          end

          def wrap_converter_for_production_progress
            original = @converter
            @converter = proc do |source, cell_type, category_code, storey|
              begin
                if original.respond_to?(:arity) && original.arity == 3
                  original.call(source, cell_type, category_code)
                else
                  original.call(source, cell_type, category_code, storey)
                end
              ensure
                advance_creation_progress
              end
            end
          end

          def wrap_topology_sync_for_production_progress
            original = @synchronize_all
            @synchronize_all = proc do
              finish_creation_progress_stage
              progress_start_stage(
                'CellSpace 재질 적용',
                total: 1,
                message: 'CellSpace 재질 일괄 적용 중'
              )

              sink = AdjacencyProgressSink.new(@production_progress, logger: @logger)
              sink.mark_stage_open('CellSpace 재질 적용')
              result = AdjacencyProgressContext.with(sink) { original.call }
              sink.finish_open_stage(
                message: 'CellSpace 재질 및 Topology 후처리 완료',
                telemetry: result || {}
              )
              result
            end
          end

          def advance_creation_progress
            return unless @production_progress_creation_stage_open

            total = @production_progress_creation_total.to_i
            @production_progress_creation_completed = [
              @production_progress_creation_completed.to_i + 1,
              total
            ].min
            progress_update_stage(
              completed: @production_progress_creation_completed,
              message: "CellSpace/State 생성: #{@production_progress_creation_completed} / #{total}"
            )
          end

          def finish_creation_progress_stage
            return unless @production_progress_creation_stage_open

            @production_progress_creation_stage_open = false
            progress_finish_stage(
              message: "CellSpace/State 생성 완료: #{@production_progress_creation_completed.to_i}개"
            )
          end

          def progress_start_stage(name, total:, message:)
            progress_call(
              :start_stage,
              name,
              total: total,
              message: message,
              cancellable: false
            )
          end

          def progress_update_stage(completed:, message:, telemetry: nil)
            progress_call(
              :update_stage,
              completed: completed,
              message: message,
              telemetry: telemetry
            )
          end

          def progress_finish_stage(message:, telemetry: nil)
            progress_call(
              :finish_stage,
              message: message,
              telemetry: telemetry
            )
          end

          def progress_call(method_name, *arguments, **keywords)
            progress = @production_progress
            return nil unless progress&.active?
            return nil unless progress.respond_to?(method_name)

            progress.public_send(method_name, *arguments, **keywords)
          rescue StandardError => e
            @logger.puts(
              "[IndoorGML] CellSpace progress #{method_name} failed: #{e.class}: #{e.message}"
            )
            nil
          end
        end

        module IndoorModelCellSpaceProgressIntegration
          def convert_cell_space_jobs_bulk(
            jobs,
            fallback_target:,
            original_active_path:,
            preserve_source: nil,
            operation_name: 'Convert Solid Groups to CellSpace',
            activate_root_context: true,
            progress: nil
          )
            previous_progress = @production_cell_space_progress
            @production_cell_space_progress = progress
            super(
              jobs,
              fallback_target: fallback_target,
              original_active_path: original_active_path,
              preserve_source: preserve_source,
              operation_name: operation_name,
              activate_root_context: activate_root_context
            )
          ensure
            @production_cell_space_progress = previous_progress
          end

          private

          def build_batch_conversion_service(*arguments, **keywords)
            service = super
            progress = @production_cell_space_progress
            service.production_progress = progress if progress && service.respond_to?(:production_progress=)
            service
          end
        end
      end

      BulkCellSpaceConversionService.prepend(
        ProductionProgress::BulkCellSpaceConversionProgressIntegration
      ) unless BulkCellSpaceConversionService.ancestors.include?(
        ProductionProgress::BulkCellSpaceConversionProgressIntegration
      )

      IndoorModel.prepend(
        ProductionProgress::IndoorModelCellSpaceProgressIntegration
      ) unless IndoorModel.ancestors.include?(
        ProductionProgress::IndoorModelCellSpaceProgressIntegration
      )

      if defined?(TopologyCoordinator)
        TopologyCoordinator.prepend(
          ProductionProgress::TopologyCoordinatorProgressIntegration
        ) unless TopologyCoordinator.ancestors.include?(
          ProductionProgress::TopologyCoordinatorProgressIntegration
        )
      end
    end
  end
end
