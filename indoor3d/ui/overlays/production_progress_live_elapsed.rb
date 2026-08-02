# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module ProductionProgressOverlayLiveElapsed
          private

          def detail_text(snapshot)
            stage = snapshot[:stage]
            elapsed = format('%.1f초', live_elapsed(snapshot))
            return format('%5.1f%% · %s', displayed_percent(snapshot), elapsed) unless stage

            stage_name = stage[:name].to_s
            completed = stage[:completed].to_i
            total = stage[:total].to_i
            if total.positive?
              format(
                '%s · %d / %d · %5.1f%% · %s',
                stage_name,
                completed,
                total,
                displayed_percent(snapshot),
                elapsed
              )
            else
              format('%s · %5.1f%% · %s', stage_name, displayed_percent(snapshot), elapsed)
            end
          end

          def live_elapsed(snapshot)
            return snapshot[:elapsed].to_f if snapshot[:terminal] == true

            started_at = snapshot[:started_at]
            return snapshot[:elapsed].to_f unless started_at

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            [now.to_f - started_at.to_f, 0.0].max
          rescue StandardError
            snapshot[:elapsed].to_f
          end
        end
      end

      if defined?(ProductionProgress::ProductionProgressOverlay)
        ProductionProgress::ProductionProgressOverlay.prepend(
          ProductionProgress::ProductionProgressOverlayLiveElapsed
        ) unless ProductionProgress::ProductionProgressOverlay.ancestors.include?(
          ProductionProgress::ProductionProgressOverlayLiveElapsed
        )
      end
    end
  end
end
