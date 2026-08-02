# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class WriteUndoModePlan
          MODES = %i[prepare_then_apply held_operation transparent_slices].freeze
          RISKY_MODES = %i[held_operation transparent_slices].freeze

          attr_reader :mode

          def initialize(mode: :prepare_then_apply, allow_risky: false)
            @mode = mode.to_sym
            raise ArgumentError, "unsupported write/undo mode: #{@mode}" unless MODES.include?(@mode)
            if risky? && !allow_risky
              raise ArgumentError, "#{@mode} requires allow_risky: true"
            end
          end

          def risky?
            RISKY_MODES.include?(@mode)
          end

          def prepare_then_apply?
            @mode == :prepare_then_apply
          end

          def held_operation?
            @mode == :held_operation
          end

          def transparent_slices?
            @mode == :transparent_slices
          end

          def description
            case @mode
            when :prepare_then_apply
              '준비는 분할하고 최종 쓰기는 단일 operation으로 적용'
            when :held_operation
              '하나의 operation을 timer callback 사이에 열린 상태로 유지'
            when :transparent_slices
              'slice마다 commit하고 후속 operation을 이전 operation에 투명 연결'
            end
          end

          def cancellation_behavior
            case @mode
            when :prepare_then_apply
              :discard_plan
            when :held_operation
              :abort_operation
            when :transparent_slices
              :leave_partial_for_undo
            end
          end

          def to_h
            {
              mode: @mode,
              risky: risky?,
              description: description,
              cancellation_behavior: cancellation_behavior
            }.freeze
          end
        end
      end
    end
  end
end
