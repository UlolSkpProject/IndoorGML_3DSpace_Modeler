# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        # Selects human-friendly progress checkpoints while keeping each stage
        # to roughly TARGET_UPDATES renderer updates.
        class AdaptiveProgressCheckpoint
          TARGET_UPDATES = 100

          attr_reader :step

          def self.step_for(total, target_updates: TARGET_UPDATES)
            total = [total.to_i, 0].max
            target_updates = [target_updates.to_i, 1].max
            raw_step = [(total.to_f / target_updates).ceil, 1].max
            nice_step(raw_step)
          end

          def self.nice_step(raw_step)
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

          def initialize(total, target_updates: TARGET_UPDATES)
            @total = [total.to_i, 0].max
            @step = self.class.step_for(@total, target_updates: target_updates)
          end

          def checkpoint?(completed)
            completed = completed.to_i
            return false if completed <= 0 || @total <= 0
            return true if completed == 1 || completed >= @total

            (completed % @step).zero?
          end
        end
      end
    end
  end
end
