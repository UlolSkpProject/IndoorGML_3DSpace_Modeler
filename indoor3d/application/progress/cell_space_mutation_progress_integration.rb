# frozen_string_literal: true

require_relative 'production_progress_session'
require_relative 'adjacency_progress_keyword_guard'
require_relative '../../ui/overlays/production_progress_overlay'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module CellSpaceMutationProgressSupport
          private

          def build_cell_space_mutation_progress_session(title:, total:, operation:, message:)
            session = ProductionProgressSession.new(
              title: title,
              total: total,
              renderer: SketchupOverlayProgressRenderer.new(model: Sketchup.active_model),
              cancellable: false,
              metadata: {
                operation: operation,
                target_count: total
              }
            )
            session.start(message: message)
            session
          rescue StandardError => error
            IndoorCore::Logger.puts(
              "[IndoorGML] #{operation} progress start failed: " \
              "#{error.class}: #{error.message}"
            )
            nil
          end

          def complete_cell_space_mutation_progress(session, message:, telemetry: nil)
            return unless session&.active?

            session.complete(message: message, telemetry: telemetry)
          rescue StandardError => error
            IndoorCore::Logger.puts(
              "[IndoorGML] CellSpace progress completion failed: " \
              "#{error.class}: #{error.message}"
            )
            nil
          end

          def fail_cell_space_mutation_progress(session, error, message:)
            return unless session&.active?

            session.fail(error, message: message)
          rescue StandardError => progress_error
            IndoorCore::Logger.puts(
              "[IndoorGML] CellSpace progress failure reporting failed: " \
              "#{progress_error.class}: #{progress_error.message}"
            )
            nil
          end

          def close_cell_space_mutation_progress(session)
            session&.close
          rescue StandardError => error
            IndoorCore::Logger.puts(
              "[IndoorGML] CellSpace progress close failed: " \
              "#{error.class}: #{error.message}"
            )
            false
          end
        end

        module IndoorModelCellSpaceCreateAutoProgress
          include CellSpaceMutationProgressSupport

          def convert_cell_space_jobs_bulk(
            jobs,
            fallback_target:,
            original_active_path:,
            preserve_source: nil,
            operation_name: 'Convert Solid Groups to CellSpace',
            activate_root_context: true,
            progress: nil
          )
            inherited_progress = progress || CellSpaceProgressContext.current
            if inherited_progress
              return super(
                jobs,
                fallback_target: fallback_target,
                original_active_path: original_active_path,
                preserve_source: preserve_source,
                operation_name: operation_name,
                activate_root_context: activate_root_context,
                progress: inherited_progress
              )
            end

            owned_session = build_cell_space_mutation_progress_session(
              title: 'CellSpace 생성',
              total: Array(jobs).length,
              operation: :cell_space_create,
              message: "CellSpace 생성 준비: #{Array(jobs).length}개"
            )
            result = CellSpaceProgressContext.with(owned_session) do
              super(
                jobs,
                fallback_target: fallback_target,
                original_active_path: original_active_path,
                preserve_source: preserve_source,
                operation_name: operation_name,
                activate_root_context: activate_root_context,
                progress: owned_session
              )
            end
            complete_cell_space_mutation_progress(
              owned_session,
              message: "CellSpace 생성 완료: #{result.converted_count.to_i}개",
              telemetry: {
                converted_count: result.converted_count.to_i,
                error_count: Array(result.errors).length,
                metrics: result.metrics || {}
              }
            )
            result
          rescue StandardError => error
            fail_cell_space_mutation_progress(
              owned_session,
              error,
              message: "CellSpace 생성 실패: #{error.message}"
            )
            raise
          ensure
            close_cell_space_mutation_progress(owned_session)
          end
        end

        module IndoorModelCellSpaceTypeChangeAutoProgress
          include CellSpaceMutationProgressSupport

          def change_cell_space_types(
            sketchup_groups,
            cell_type,
            category_code = nil,
            operation_name: 'Change CellSpace Types',
            progress: nil
          )
            return super if progress

            owned_session = build_cell_space_mutation_progress_session(
              title: 'CellSpace Type 변경',
              total: Array(sketchup_groups).length,
              operation: :cell_space_type_change,
              message: "CellSpace Type 변경 준비: #{Array(sketchup_groups).length}개"
            )
            result = super(
              sketchup_groups,
              cell_type,
              category_code,
              operation_name: operation_name,
              progress: owned_session
            )
            complete_cell_space_mutation_progress(
              owned_session,
              message: "CellSpace Type 변경 완료: #{Array(result).length}개",
              telemetry: { changed_count: Array(result).length }
            )
            result
          rescue StandardError => error
            fail_cell_space_mutation_progress(
              owned_session,
              error,
              message: "CellSpace Type 변경 실패: #{error.message}"
            )
            raise
          ensure
            close_cell_space_mutation_progress(owned_session)
          end
        end
      end

      IndoorModel.prepend(
        ProductionProgress::IndoorModelCellSpaceCreateAutoProgress
      ) unless IndoorModel.ancestors.include?(
        ProductionProgress::IndoorModelCellSpaceCreateAutoProgress
      )

      IndoorModel.prepend(
        ProductionProgress::IndoorModelCellSpaceTypeChangeAutoProgress
      ) unless IndoorModel.ancestors.include?(
        ProductionProgress::IndoorModelCellSpaceTypeChangeAutoProgress
      )
    end
  end
end
