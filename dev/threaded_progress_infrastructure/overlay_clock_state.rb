# frozen_string_literal: true

require_relative 'overlay_state'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class OverlayState
          def tick_elapsed(elapsed:, **metrics)
            current_elapsed = @snapshot[:elapsed].to_f
            next_elapsed = [elapsed.to_f, current_elapsed].max
            normalized_metrics = metrics.each_with_object({}) do |(key, value), result|
              result[key.to_sym] = value
            end

            @snapshot = @snapshot.merge(normalized_metrics).merge(
              elapsed: next_elapsed
            ).freeze
          end
        end
      end
    end
  end
end
