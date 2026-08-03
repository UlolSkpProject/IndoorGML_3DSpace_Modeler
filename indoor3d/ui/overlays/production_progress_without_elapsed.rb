# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module ProductionProgressOverlayWithoutElapsed
          private

          def detail_text(snapshot)
            stage = snapshot[:stage]
            return format('%5.1f%%', displayed_percent(snapshot)) unless stage

            parts = []
            position = stage_position_text(snapshot, stage)
            parts << position unless position.nil?
            parts << stage[:name].to_s

            completed = stage[:completed].to_i
            total = stage[:total].to_i
            parts << "#{completed} / #{total}" if total.positive?
            parts << format('%5.1f%%', displayed_percent(snapshot))
            parts.join(' · ')
          end
        end

        module ProductionProgressRendererEveryCount
          private

          def stage_signature(snapshot)
            stage = snapshot[:stage]
            [
              stage&.dig(:name),
              stage&.dig(:status),
              stage&.dig(:completed),
              stage&.dig(:total),
              snapshot[:status]
            ]
          end
        end
      end

      if defined?(ProductionProgress::ProductionProgressOverlay)
        ProductionProgress::ProductionProgressOverlay.prepend(
          ProductionProgress::ProductionProgressOverlayWithoutElapsed
        ) unless ProductionProgress::ProductionProgressOverlay.ancestors.include?(
          ProductionProgress::ProductionProgressOverlayWithoutElapsed
        )
      end

      if defined?(ProductionProgress::SketchupOverlayProgressRenderer)
        ProductionProgress::SketchupOverlayProgressRenderer.prepend(
          ProductionProgress::ProductionProgressRendererEveryCount
        ) unless ProductionProgress::SketchupOverlayProgressRenderer.ancestors.include?(
          ProductionProgress::ProductionProgressRendererEveryCount
        )
      end
    end
  end
end
