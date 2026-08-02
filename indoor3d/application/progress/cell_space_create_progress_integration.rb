# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
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
                'Adjacency/Transition 생성',
                total: 1,
                message: 'Adjacency/Transition 생성 중'
              )
              result = original.call
              progress_update_stage(
                completed: 1,
                message: 'Adjacency/Transition 생성 완료',
                telemetry: result || {}
              )
              progress_finish_stage(
                message: 'Adjacency/Transition 생성 완료',
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
    end
  end
end
