# frozen_string_literal: true

require_relative 'cell_space_conversion_preflight_prototype'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionPreflightRunner
        DEFAULT_OPTIONS = {
          fallback_cell_type: CellSpaceType::GENERAL,
          fallback_category_code: nil,
          slice_budget_ms: 8.0,
          max_items_per_slice: 25
        }.freeze unless const_defined?(:DEFAULT_OPTIONS, false)

        POLL_INTERVAL = 0.1 unless const_defined?(:POLL_INTERVAL, false)

        class << self
          def run!(**options)
            stop_poll_timer

            selected_count = selected_container_count
            if selected_count.zero?
              puts '[CELLSPACE PREFLIGHT RUNNER] Solid Group 또는 ComponentInstance를 먼저 선택하세요.'
              return false
            end

            prototype.install!
            started = prototype.start!(**DEFAULT_OPTIONS.merge(options))

            if started
              puts "[CELLSPACE PREFLIGHT RUNNER] started (selected containers=#{selected_count})"
              puts '[CELLSPACE PREFLIGHT RUNNER] 완료 시 status/verify 결과를 자동 출력합니다.'
              start_poll_timer
            else
              puts '[CELLSPACE PREFLIGHT RUNNER] start failed'
            end

            started
          rescue StandardError => e
            stop_poll_timer
            puts "[CELLSPACE PREFLIGHT RUNNER] failed: #{e.class}: #{e.message}"
            false
          end

          def status!
            prototype.status!
          end

          def verify!
            prototype.verify!
          end

          def cancel!
            prototype.cancel!
          end

          def close!
            stop_poll_timer
            prototype.close!
          end

          private

          def prototype
            CellSpaceConversionPreflightPrototype
          end

          def selected_container_count
            model = Sketchup.active_model
            return 0 unless model&.respond_to?(:selection)

            model.selection.to_a.count do |entity|
              entity.is_a?(Sketchup::Group) ||
                entity.is_a?(Sketchup::ComponentInstance)
            end
          rescue StandardError
            0
          end

          def start_poll_timer
            stop_poll_timer
            @poll_timer_id = UI.start_timer(POLL_INTERVAL, true) do
              snapshot = current_session_snapshot
              next true unless snapshot[:terminal]

              stop_poll_timer
              puts '[CELLSPACE PREFLIGHT RUNNER] terminal result'
              status!
              verify!
              false
            rescue StandardError => e
              stop_poll_timer
              puts "[CELLSPACE PREFLIGHT RUNNER] result polling failed: #{e.class}: #{e.message}"
              false
            end
          end

          def stop_poll_timer
            timer_id = @poll_timer_id
            @poll_timer_id = nil
            return if timer_id.nil?
            return unless UI.respond_to?(:stop_timer)

            UI.stop_timer(timer_id)
          rescue StandardError
            nil
          end

          def current_session_snapshot
            controller = prototype.send(:controller)
            session = controller.instance_variable_get(:@session)
            session&.snapshot || {}
          end
        end
      end
    end
  end
end

runner =
  ULOL::Indoor3DGmlModeler::IndoorCore::
    CellSpaceConversionPreflightRunner

runner.run!
