# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        # Runtime refresh stages are immediately followed by another stage. Rendering
        # an intermediate 100% snapshot forces an expensive viewport refresh and can
        # leave a misleading "completed" frame visible while the next phase starts.
        # Keep the last in-progress frame until either the next stage or the terminal
        # session snapshot replaces it.
        class RuntimeRefreshProgressRenderer < SketchupOverlayProgressRenderer
          def update(snapshot)
            return true if defer_intermediate_completion?(snapshot)

            super
          end

          private

          def defer_intermediate_completion?(snapshot)
            return false unless snapshot.respond_to?(:[])
            return false if snapshot[:terminal] == true

            stage = snapshot[:stage]
            return false unless stage.respond_to?(:[])

            status = stage[:status].to_sym
            return true if status == :completed

            total = stage[:total].to_i
            completed = stage[:completed].to_i
            total.positive? && completed >= total
          rescue StandardError
            false
          end
        end

        module RuntimeRefreshStageHandoff
          private

          def build_runtime_refresh_progress_session(initial_model_load)
            model = @model || Sketchup.active_model
            stage_count = initial_model_load == true ? 6 : 4
            ProductionProgressSession.new(
              title: initial_model_load == true ? 'IndoorGML 모델 열기' : 'IndoorGML Runtime Refresh',
              total: stage_count,
              renderer: RuntimeRefreshProgressRenderer.new(model: model),
              cancellable: false,
              metadata: {
                operation: :runtime_refresh,
                initial_model_load: initial_model_load == true,
                stage_count: stage_count,
                model_object_id: model&.object_id
              }
            )
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Runtime refresh progress start failed: #{e.class}: #{e.message}"
            )
            nil
          end
        end
      end

      if defined?(IndoorModel)
        IndoorModel.prepend(
          ProductionProgress::RuntimeRefreshStageHandoff
        ) unless IndoorModel.ancestors.include?(
          ProductionProgress::RuntimeRefreshStageHandoff
        )
      end
    end
  end
end
