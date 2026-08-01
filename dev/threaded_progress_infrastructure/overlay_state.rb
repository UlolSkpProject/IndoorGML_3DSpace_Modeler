# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class OverlayState
          TERMINAL_TYPES = %i[completed cancelled failed].freeze
          VISIBLE_TYPES = %i[starting started progress completed cancelled failed].freeze

          def initialize
            @snapshot = idle_snapshot
          end

          def apply(event)
            payload = symbolize(event)
            type = payload.fetch(:type, :progress).to_sym
            total = [payload.fetch(:total, @snapshot[:total]).to_i, 0].max
            completed = [payload.fetch(:completed, @snapshot[:completed]).to_i, 0].max
            completed = [completed, total].min if total.positive?
            percent = normalized_percent(payload[:percent], completed, total)

            @snapshot = @snapshot.merge(payload).merge(
              type: type,
              total: total,
              completed: completed,
              percent: percent,
              visible: VISIBLE_TYPES.include?(type),
              terminal: TERMINAL_TYPES.include?(type),
              message: message_for(type, payload)
            ).freeze
          end

          def hide!
            @snapshot = @snapshot.merge(visible: false).freeze
          end

          def reset!
            @snapshot = idle_snapshot
          end

          def visible?
            @snapshot[:visible] == true
          end

          def terminal?
            @snapshot[:terminal] == true
          end

          def snapshot
            @snapshot
          end

          private

          def symbolize(event)
            event.to_h.each_with_object({}) do |(key, value), result|
              result[key.to_sym] = value
            end
          end

          def normalized_percent(value, completed, total)
            percent = if value.nil?
                        total.positive? ? completed.fdiv(total) * 100.0 : 0.0
                      else
                        value.to_f
                      end
            [[percent, 0.0].max, 100.0].min
          end

          def message_for(type, payload)
            explicit = payload[:message].to_s.strip
            return explicit unless explicit.empty?

            case type
            when :starting then '작업 준비 중'
            when :started, :progress then '순수 Ruby worker 실행 중'
            when :completed then '작업 완료'
            when :cancelled then '작업 취소됨'
            when :failed
              error = payload[:error_message].to_s.strip
              error.empty? ? '작업 실패' : "작업 실패: #{error}"
            else
              '대기 중'
            end
          end

          def idle_snapshot
            {
              type: :idle,
              total: 0,
              completed: 0,
              percent: 0.0,
              elapsed: 0.0,
              visible: false,
              terminal: false,
              message: '대기 중'
            }.freeze
          end
        end
      end
    end
  end
end
