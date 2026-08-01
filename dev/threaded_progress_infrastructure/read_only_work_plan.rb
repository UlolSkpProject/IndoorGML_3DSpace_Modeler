# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class ReadOnlyWorkPlan
          MODES = %i[single_pass stress].freeze

          attr_reader :mode, :target_count, :total

          def initialize(mode:, target_count:, stress_iterations:)
            @mode = normalize_mode(mode)
            @target_count = [target_count.to_i, 0].max
            raise ArgumentError, 'target_count must be positive' unless @target_count.positive?

            @total = if single_pass?
                       @target_count
                     else
                       [stress_iterations.to_i, 1].max
                     end
          end

          def single_pass?
            @mode == :single_pass
          end

          def stress?
            @mode == :stress
          end

          def target_index(work_index)
            index = work_index.to_i
            raise IndexError, 'work index outside plan' if index.negative? || index >= @total

            single_pass? ? index : index % @target_count
          end

          def count_label
            single_pass? ? 'Entity' : 'API 조회'
          end

          def description
            single_pass? ? '실제 Entity 1회 순회' : '반복 API 조회 부하 테스트'
          end

          private

          def normalize_mode(value)
            mode = value.to_sym
            return mode if MODES.include?(mode)

            raise ArgumentError, "unsupported read-only work mode: #{value.inspect}"
          rescue NoMethodError
            raise ArgumentError, "unsupported read-only work mode: #{value.inspect}"
          end
        end
      end
    end
  end
end
