# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class StagedJobContract
          PHASES = %i[prepare compute apply finalize].freeze
          TERMINAL_TYPES = %i[completed cancelled failed].freeze
          DEFAULT_WEIGHTS = {
            prepare: 0.20,
            compute: 0.60,
            apply: 0.15,
            finalize: 0.05
          }.freeze

          attr_reader :weights

          def initialize(weights: DEFAULT_WEIGHTS)
            normalized = normalize_weights(weights)
            @weights = normalized.freeze
            @phase_offsets = build_phase_offsets(normalized).freeze
          end

          def overall_percent(phase:, phase_percent:)
            phase = phase.to_sym
            return 100.0 if phase == :completed
            return 0.0 unless PHASES.include?(phase)

            local = clamp_percent(phase_percent)
            offset = @phase_offsets.fetch(phase)
            weight = @weights.fetch(phase)
            clamp_percent((offset + (weight * local.fdiv(100.0))) * 100.0)
          end

          def valid_transition?(from:, to:)
            from = from.to_sym
            to = to.to_sym
            return true if from == to
            return true if TERMINAL_TYPES.include?(to)

            case from
            when :idle then to == :prepare
            when :prepare then to == :compute
            when :compute then to == :apply
            when :apply then to == :finalize
            when :finalize then to == :completed
            else false
            end
          end

          def assert_transition!(from:, to:)
            return true if valid_transition?(from: from, to: to)

            raise ArgumentError, "invalid staged job transition: #{from} -> #{to}"
          end

          private

          def normalize_weights(weights)
            source = weights.to_h.each_with_object({}) do |(key, value), result|
              result[key.to_sym] = [value.to_f, 0.0].max
            end
            missing = PHASES.reject { |phase| source.key?(phase) }
            raise ArgumentError, "missing phase weights: #{missing.join(', ')}" unless missing.empty?

            total = PHASES.sum { |phase| source.fetch(phase) }
            raise ArgumentError, 'phase weight total must be positive' unless total.positive?

            PHASES.each_with_object({}) do |phase, result|
              result[phase] = source.fetch(phase).fdiv(total)
            end
          end

          def build_phase_offsets(weights)
            offset = 0.0
            PHASES.each_with_object({}) do |phase, result|
              result[phase] = offset
              offset += weights.fetch(phase)
            end
          end

          def clamp_percent(value)
            [[value.to_f, 0.0].max, 100.0].min
          end
        end
      end
    end
  end
end
