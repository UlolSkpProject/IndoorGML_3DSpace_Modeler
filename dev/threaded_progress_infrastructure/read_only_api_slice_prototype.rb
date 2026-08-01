# frozen_string_literal: true

require_relative 'main_thread_slice_runner'
require_relative 'overlay_state'
require_relative 'overlay_prototype'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module MainThreadSlicePrototype
        TIMER_INTERVAL = 0.01
        TERMINAL_HOLD_SECONDS = 2.0
        DEFAULT_ITERATIONS = 50_000
        DEFAULT_SLICE_BUDGET_MS = 8.0
        DEFAULT_MAX_ITEMS_PER_SLICE = 100

        class Controller
          def initialize
            @main_thread = Thread.current
            @state = ThreadedProgressInfrastructure::OverlayState.new
            @overlay = nil
            @registered_model = nil
            @job_model = nil
            @targets = []
            @runner = nil
            @timer_id = nil
            @hide_timer_id = nil
            @read_checksum = 0
          end

          def install
            assert_main_thread!
            close_worker_prototype
            ensure_registered(Sketchup.active_model)
            invalidate_view
            true
          end

          def start_job(
            iterations: DEFAULT_ITERATIONS,
            slice_budget_ms: DEFAULT_SLICE_BUDGET_MS,
            max_items_per_slice: DEFAULT_MAX_ITEMS_PER_SLICE
          )
            assert_main_thread!
            return false if @runner&.running?

            close_worker_prototype
            model = Sketchup.active_model
            return false unless ensure_registered(model)

            stop_timers
            @job_model = model
            @targets = collect_targets(model)
            if @targets.empty?
              @state.apply(type: :failed, error_message: '조회할 SketchUp entity가 없습니다.')
              invalidate_view
              schedule_hide
              return false
            end

            total = [iterations.to_i, 1].max
            @read_checksum = 0
            @state.reset!
            @runner = ThreadedProgressInfrastructure::MainThreadSliceRunner.new(
              total: total,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice
            ) do |index|
              inspect_entity(@targets[index % @targets.length], index)
            end
            @runner.start
            apply_runner_snapshot(@runner.snapshot)
            invalidate_view
            start_timer
            true
          end

          def cancel_job
            assert_main_thread!
            return false unless @runner

            @runner.cancel!
            true
          end

          def status
            assert_main_thread!
            runner_snapshot = @runner&.snapshot || {}
            snapshot = @state.snapshot.merge(
              current_thread_id: Thread.current.object_id,
              main_thread_id: @main_thread.object_id,
              runner_type: runner_snapshot[:type],
              runner_terminal: runner_snapshot[:terminal],
              slice_budget_ms: runner_snapshot[:slice_budget_ms],
              slice_count: runner_snapshot[:slice_count],
              last_slice_items: runner_snapshot[:last_slice_items],
              last_slice_ms: runner_snapshot[:last_slice_ms],
              max_slice_ms: runner_snapshot[:max_slice_ms],
              overrun_count: runner_snapshot[:overrun_count],
              checksum: runner_snapshot[:checksum],
              target_count: @targets.length,
              timer_active: !@timer_id.nil?,
              overlay_valid: @overlay&.valid? == true,
              registered_model_id: @registered_model&.object_id
            )
            puts "[MAIN THREAD SLICE PROTOTYPE] #{snapshot.inspect}"
            snapshot
          end

          def close
            assert_main_thread!
            @runner&.cancel!
            stop_timers
            @state.hide!
            invalidate_view
            unregister_overlay
            @targets = []
            @job_model = nil
            true
          end

          private

          def collect_targets(model)
            selected = model.selection.to_a
            targets = selected.empty? ? model.entities.to_a : selected
            targets.select { |entity| entity.respond_to?(:valid?) && entity.valid? }
          rescue StandardError => e
            puts "[MAIN THREAD SLICE PROTOTYPE] target collection failed: #{e.class}: #{e.message}"
            []
          end

          def inspect_entity(entity, index)
            assert_main_thread!
            return 0 unless entity&.valid?

            value = index.to_i
            value ^= entity.entityID.to_i if entity.respond_to?(:entityID)
            value ^= entity.persistent_id.to_i if entity.respond_to?(:persistent_id)
            value ^= entity.typename.to_s.bytesize if entity.respond_to?(:typename)

            if entity.respond_to?(:layer)
              layer = entity.layer
              value ^= layer.name.to_s.bytesize if layer
            end
            value ^= 0x01 if entity.respond_to?(:visible?) && entity.visible?
            value ^= 0x02 if entity.respond_to?(:hidden?) && entity.hidden?
            value ^= 0x04 if entity.respond_to?(:locked?) && entity.locked?

            if entity.respond_to?(:bounds)
              center = entity.bounds.center
              value ^= (center.x.to_f * 1_000.0).round
              value ^= (center.y.to_f * 1_000.0).round
              value ^= (center.z.to_f * 1_000.0).round
            end

            @read_checksum = ((@read_checksum * 33) ^ value) & 0xFFFF_FFFF
          end

          def start_timer
            stop_timer
            @timer_id = UI.start_timer(TIMER_INTERVAL, true) { pump }
          end

          def pump
            assert_main_thread!
            unless Sketchup.active_model.equal?(@job_model)
              @runner&.cancel!
              @state.apply(type: :failed, error_message: '작업 중 활성 모델이 변경되었습니다.')
              finish_terminal
              return false
            end

            runner_snapshot = @runner.tick
            apply_runner_snapshot(runner_snapshot)
            invalidate_view
            finish_terminal if runner_snapshot[:terminal]
            true
          rescue StandardError => e
            @state.apply(type: :failed, error_message: "#{e.class}: #{e.message}")
            invalidate_view
            finish_terminal
            false
          end

          def apply_runner_snapshot(snapshot)
            type = snapshot[:type] == :running ? :progress : snapshot[:type]
            current_item = if snapshot[:terminal]
                             snapshot[:completed]
                           else
                             snapshot[:completed].to_i + 1
                           end
            @state.apply(
              type: type,
              total: snapshot[:total],
              completed: snapshot[:completed],
              current_item: current_item,
              current_item_percent: 0.0,
              effective_completed: snapshot[:completed].to_f,
              percent: snapshot[:percent],
              elapsed: snapshot[:elapsed],
              message: message_for(snapshot[:type]),
              slice_budget_ms: snapshot[:slice_budget_ms],
              slice_count: snapshot[:slice_count],
              last_slice_items: snapshot[:last_slice_items],
              last_slice_ms: snapshot[:last_slice_ms],
              max_slice_ms: snapshot[:max_slice_ms],
              overrun_count: snapshot[:overrun_count],
              read_checksum: @read_checksum
            )
          end

          def message_for(type)
            case type
            when :idle then 'SketchUp API read-only 순회 대기'
            when :running then "SketchUp API read-only 순회 중 (대상 #{@targets.length}개)"
            when :completed then 'SketchUp API read-only 순회 완료'
            when :cancelled then 'SketchUp API read-only 순회 취소됨'
            when :failed then 'SketchUp API read-only 순회 실패'
            else 'SketchUp API read-only 순회 준비 중'
            end
          end

          def ensure_registered(model)
            return false unless model&.respond_to?(:overlays)
            return true if @registered_model.equal?(model) && @overlay&.valid?

            unregister_overlay
            remove_stale_overlay(model)
            @overlay = ThreadedProgressOverlayPrototype::ProgressOverlay.new(@state)
            model.overlays.add(@overlay)
            @overlay.enabled = true if @overlay.respond_to?(:enabled=)
            @registered_model = model
            true
          rescue StandardError => e
            puts "[MAIN THREAD SLICE PROTOTYPE] overlay registration failed: #{e.class}: #{e.message}"
            false
          end

          def unregister_overlay
            model = @registered_model
            overlay = @overlay
            @registered_model = nil
            @overlay = nil
            return unless model&.respond_to?(:overlays)
            return unless overlay&.valid?

            model.overlays.remove(overlay)
          rescue StandardError
            nil
          end

          def remove_stale_overlay(model)
            stale = []
            model.overlays.each do |candidate|
              next unless candidate.overlay_id == ThreadedProgressOverlayPrototype::ProgressOverlay::OVERLAY_ID

              stale << candidate
            end
            stale.each { |candidate| model.overlays.remove(candidate) }
          end

          def finish_terminal
            stop_timer
            schedule_hide
          end

          def schedule_hide
            stop_hide_timer
            @hide_timer_id = UI.start_timer(TERMINAL_HOLD_SECONDS, false) do
              @hide_timer_id = nil
              @state.hide!
              invalidate_view
              false
            end
          end

          def stop_timers
            stop_timer
            stop_hide_timer
          end

          def stop_timer
            stop_timer_id(:@timer_id)
          end

          def stop_hide_timer
            stop_timer_id(:@hide_timer_id)
          end

          def stop_timer_id(variable_name)
            timer_id = instance_variable_get(variable_name)
            instance_variable_set(variable_name, nil)
            return if timer_id.nil?
            return unless UI.respond_to?(:stop_timer)

            UI.stop_timer(timer_id)
          rescue StandardError
            nil
          end

          def invalidate_view
            @registered_model&.active_view&.invalidate
          rescue StandardError
            nil
          end

          def close_worker_prototype
            ThreadedProgressOverlayPrototype.close!
          rescue StandardError
            nil
          end

          def assert_main_thread!
            return if Thread.current.equal?(@main_thread)

            raise "SketchUp API access attempted outside main thread: #{Thread.current.object_id}"
          end
        end

        class << self
          def install!
            controller.install
          end

          def start!(
            iterations: DEFAULT_ITERATIONS,
            slice_budget_ms: DEFAULT_SLICE_BUDGET_MS,
            max_items_per_slice: DEFAULT_MAX_ITEMS_PER_SLICE
          )
            controller.start_job(
              iterations: iterations,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice
            )
          end

          def cancel!
            controller.cancel_job
          end

          def status!
            controller.status
          end

          def close!
            controller.close
          end

          private

          def controller
            @controller ||= Controller.new
          end
        end
      end
    end
  end
end

puts '[MAIN THREAD SLICE PROTOTYPE] installed'
puts 'Install: ...::MainThreadSlicePrototype.install!'
puts 'Start  : ...::MainThreadSlicePrototype.start!'
puts 'Cancel : ...::MainThreadSlicePrototype.cancel!'
puts 'Status : ...::MainThreadSlicePrototype.status!'
puts 'Close  : ...::MainThreadSlicePrototype.close!'
