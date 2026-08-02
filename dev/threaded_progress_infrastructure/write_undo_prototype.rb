# frozen_string_literal: true

require_relative 'main_thread_slice_runner'
require_relative 'overlay_state'
require_relative 'overlay_semantics_patch'
require_relative 'write_undo_mode_plan'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module WriteUndoPrototype
        TIMER_INTERVAL = 0.01
        TERMINAL_HOLD_SECONDS = 2.0
        DEFAULT_ITEM_COUNT = 500
        DEFAULT_SLICE_BUDGET_MS = 8.0
        DEFAULT_MAX_ITEMS_PER_SLICE = 50
        ATTRIBUTE_DICTIONARY = 'ULOL_DEV_WRITE_UNDO_PROBE'
        ATTRIBUTE_RUN_ID = 'run_id'
        ATTRIBUTE_MODE = 'mode'
        GROUP_NAME_PREFIX = '[DEV] Write Undo Probe'

        class TransactionObserver < Sketchup::ModelObserver
          def initialize(&callback)
            @callback = callback
          end

          def onTransactionStart(model)
            @callback.call(:start, model)
          end

          def onTransactionCommit(model)
            @callback.call(:commit, model)
          end

          def onTransactionAbort(model)
            @callback.call(:abort, model)
          end

          def onTransactionEmpty(model)
            @callback.call(:empty, model)
          end

          def onTransactionUndo(model)
            @callback.call(:undo, model)
          end

          def onTransactionRedo(model)
            @callback.call(:redo, model)
          end
        end

        class Controller
          def initialize
            @main_thread = Thread.current
            @state = ThreadedProgressInfrastructure::OverlayState.new
            @overlay = nil
            @registered_model = nil
            @job_model = nil
            @runner = nil
            @timer_id = nil
            @hide_timer_id = nil
            @observer = nil
            @observer_model = nil
            reset_job_state
          end

          def install
            assert_main_thread!
            close_other_prototypes
            ensure_registered(Sketchup.active_model)
            attach_transaction_observer(Sketchup.active_model)
            invalidate_view
            true
          end

          def start_job(
            mode: :prepare_then_apply,
            item_count: DEFAULT_ITEM_COUNT,
            slice_budget_ms: DEFAULT_SLICE_BUDGET_MS,
            max_items_per_slice: DEFAULT_MAX_ITEMS_PER_SLICE,
            allow_risky: false
          )
            assert_main_thread!
            return false if running?

            close_other_prototypes
            model = Sketchup.active_model
            return false unless ensure_registered(model)

            attach_transaction_observer(model)
            stop_timers
            reset_job_state

            @mode_plan = ThreadedProgressInfrastructure::WriteUndoModePlan.new(
              mode: mode,
              allow_risky: allow_risky
            )
            @job_model = model
            @item_count = [item_count.to_i, 1].max
            @run_id = build_run_id
            @base_point = choose_base_point(model)
            @plans = Array.new(@item_count)
            @state.reset!
            @started_at = monotonic_time

            puts "[WRITE UNDO PROTOTYPE] mode=#{@mode_plan.mode} risky=#{@mode_plan.risky?}"
            puts "[WRITE UNDO PROTOTYPE] #{@mode_plan.description}"

            if @mode_plan.prepare_then_apply?
              start_prepare_runner(slice_budget_ms, max_items_per_slice)
            elsif @mode_plan.held_operation?
              start_held_operation_runner(slice_budget_ms, max_items_per_slice)
            else
              start_transparent_runner(slice_budget_ms, max_items_per_slice)
            end

            apply_runner_snapshot(@runner.snapshot)
            invalidate_view
            start_timer
            true
          rescue StandardError => e
            fail_job(e)
            false
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
            group_snapshot = current_group_snapshot
            snapshot = @state.snapshot.merge(
              mode: @mode_plan&.mode,
              risky_mode: @mode_plan&.risky? == true,
              phase: @phase,
              run_id: @run_id,
              item_count: @item_count,
              created_items: @created_items,
              apply_ms: @apply_ms,
              operation_open_assumed: @operation_open_assumed,
              operation_interference: @operation_interference,
              transparent_slice_count: @transparent_slice_count,
              transaction_event_count: @transaction_events.length,
              transaction_events: @transaction_events.last(12),
              rollback_status: @rollback_status,
              group_count: group_snapshot[:group_count],
              edge_count: group_snapshot[:edge_count],
              runner_type: runner_snapshot[:type],
              runner_terminal: runner_snapshot[:terminal],
              slice_count: runner_snapshot[:slice_count],
              last_slice_items: runner_snapshot[:last_slice_items],
              last_slice_ms: runner_snapshot[:last_slice_ms],
              max_slice_ms: runner_snapshot[:max_slice_ms],
              overrun_count: runner_snapshot[:overrun_count],
              current_thread_id: Thread.current.object_id,
              main_thread_id: @main_thread.object_id,
              timer_active: !@timer_id.nil?,
              overlay_valid: @overlay&.valid? == true,
              registered_model_id: @registered_model&.object_id
            )
            puts "[WRITE UNDO PROTOTYPE] #{snapshot.inspect}"
            snapshot
          end

          def verify(expected = :created)
            assert_main_thread!
            expected = expected.to_sym
            snapshot = current_group_snapshot
            passed = case expected
                     when :created, :redone
                       snapshot[:group_count] == 1 && snapshot[:edge_count] == @item_count
                     when :undone, :rolled_back
                       snapshot[:group_count].zero? && snapshot[:edge_count].zero?
                     else
                       raise ArgumentError, "unsupported expected state: #{expected}"
                     end
            result = snapshot.merge(
              expected: expected,
              expected_edge_count: expected == :created || expected == :redone ? @item_count : 0,
              passed: passed
            )
            puts "[WRITE UNDO VERIFY] #{result.inspect}"
            result
          end

          def undo
            assert_main_thread!
            Sketchup.send_action('editUndo:')
            invalidate_view
            true
          end

          def redo
            assert_main_thread!
            Sketchup.send_action('editRedo:')
            invalidate_view
            true
          end

          def cleanup
            assert_main_thread!
            return false if running?

            model = Sketchup.active_model
            groups = all_probe_groups(model)
            return true if groups.empty?

            model.start_operation('[DEV] Write Undo Probe Cleanup', true)
            model.entities.erase_entities(groups.select(&:valid?))
            model.commit_operation
            invalidate_view
            true
          rescue StandardError => e
            model.abort_operation rescue nil
            puts "[WRITE UNDO PROTOTYPE] cleanup failed: #{e.class}: #{e.message}"
            false
          end

          def close
            assert_main_thread!
            @runner&.cancel!
            close_open_operation_for_shutdown
            stop_timers
            @state.hide!
            invalidate_view
            detach_transaction_observer
            unregister_overlay
            @job_model = nil
            true
          end

          private

          def running?
            @runner&.running? == true || @operation_open_assumed
          end

          def reset_job_state
            @mode_plan = nil
            @phase = :idle
            @run_id = nil
            @item_count = 0
            @base_point = nil
            @plans = []
            @root_group = nil
            @created_items = 0
            @apply_ms = nil
            @operation_open_assumed = false
            @operation_interference = false
            @expected_transaction_event = nil
            @transparent_slice_count = 0
            @transaction_events = []
            @rollback_status = :none
            @started_at = nil
          end

          def start_prepare_runner(slice_budget_ms, max_items_per_slice)
            @phase = :prepare
            @runner = build_runner(slice_budget_ms, max_items_per_slice) do |index|
              @plans[index] = build_item_plan(index)
              index
            end
            @runner.start
          end

          def start_held_operation_runner(slice_budget_ms, max_items_per_slice)
            @phase = :write
            begin_operation('[DEV] Held Operation Probe')
            @root_group = create_root_group
            @runner = build_runner(slice_budget_ms, max_items_per_slice) do |index|
              add_planned_edge(build_item_plan(index))
              @created_items += 1
              index
            end
            @runner.start
          end

          def start_transparent_runner(slice_budget_ms, max_items_per_slice)
            @phase = :write
            @runner = build_runner(slice_budget_ms, max_items_per_slice) do |index|
              add_planned_edge(build_item_plan(index))
              @created_items += 1
              index
            end
            @runner.start
          end

          def build_runner(slice_budget_ms, max_items_per_slice, &step)
            ThreadedProgressInfrastructure::MainThreadSliceRunner.new(
              total: @item_count,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice,
              &step
            )
          end

          def start_timer
            stop_timer
            @timer_id = UI.start_timer(TIMER_INTERVAL, true) { pump }
          end

          def pump
            assert_main_thread!
            unless Sketchup.active_model.equal?(@job_model)
              handle_model_change
              return false
            end

            if @mode_plan.prepare_then_apply?
              pump_prepare_then_apply
            elsif @mode_plan.held_operation?
              pump_held_operation
            else
              pump_transparent_slices
            end
            true
          rescue StandardError => e
            fail_job(e)
            false
          end

          def pump_prepare_then_apply
            snapshot = @runner.tick
            apply_runner_snapshot(snapshot)
            invalidate_view
            return unless snapshot[:terminal]

            if snapshot[:type] == :completed
              apply_prepared_plan
            else
              @rollback_status = :not_needed
              finish_terminal(snapshot[:type])
            end
          end

          def pump_held_operation
            if @operation_interference
              @runner.cancel!
              @state.apply(type: :failed, error_message: '열린 operation이 외부 transaction에 의해 중단되었습니다.')
              @rollback_status = :unknown_after_interference
              @operation_open_assumed = false
              finish_terminal(:failed)
              return
            end

            snapshot = @runner.tick
            apply_runner_snapshot(snapshot)
            invalidate_view
            return unless snapshot[:terminal]

            if snapshot[:type] == :completed
              commit_open_operation
              @rollback_status = :committed
            else
              abort_open_operation
              @rollback_status = :aborted
            end
            finish_terminal(snapshot[:type])
          end

          def pump_transparent_slices
            if @runner.snapshot[:cancel_requested]
              snapshot = @runner.tick
              apply_runner_snapshot(snapshot)
              @rollback_status = :partial_geometry_left_for_single_undo
              finish_terminal(snapshot[:type])
              return
            end

            transparent = @transparent_slice_count.positive?
            begin_operation('[DEV] Transparent Slice Probe', transparent: transparent)
            @root_group ||= create_root_group
            snapshot = @runner.tick
            commit_open_operation
            @transparent_slice_count += 1
            apply_runner_snapshot(snapshot)
            invalidate_view
            return unless snapshot[:terminal]

            @rollback_status = snapshot[:type] == :completed ? :committed_chain : :partial_geometry_left_for_single_undo
            finish_terminal(snapshot[:type])
          rescue StandardError => e
            commit_open_operation if @operation_open_assumed
            @rollback_status = :partial_geometry_left_after_error
            raise e
          end

          def apply_prepared_plan
            @phase = :apply
            @state.apply(
              type: :progress,
              total: @item_count,
              completed: @item_count,
              percent: 100.0,
              elapsed: elapsed,
              message: '준비 완료 — 단일 operation 적용 중',
              count_label: '계획',
              show_current_item_progress: false
            )
            invalidate_view

            started = monotonic_time
            begin_operation('[DEV] Prepare Then Apply Probe')
            @root_group = create_root_group
            @plans.each do |plan|
              add_planned_edge(plan)
              @created_items += 1
            end
            commit_open_operation
            @apply_ms = (monotonic_time - started) * 1000.0
            @rollback_status = :committed
            @phase = :completed
            @state.apply(
              type: :completed,
              total: @item_count,
              completed: @created_items,
              percent: 100.0,
              elapsed: elapsed,
              message: '단일 operation 적용 완료',
              count_label: '생성',
              show_current_item_progress: false,
              apply_ms: @apply_ms
            )
            invalidate_view
            finish_terminal(:completed)
          rescue StandardError => e
            abort_open_operation if @operation_open_assumed
            @rollback_status = :aborted
            raise e
          end

          def begin_operation(name, transparent: false)
            @expected_transaction_event = nil
            status = @job_model.start_operation(name, true, false, transparent)
            raise "start_operation failed: #{name}" unless status

            @operation_open_assumed = true
            true
          end

          def commit_open_operation
            return true unless @operation_open_assumed

            @expected_transaction_event = :commit
            status = @job_model.commit_operation
            @operation_open_assumed = false
            @expected_transaction_event = nil
            raise 'commit_operation failed' unless status

            true
          end

          def abort_open_operation
            return true unless @operation_open_assumed

            @expected_transaction_event = :abort
            status = @job_model.abort_operation
            @operation_open_assumed = false
            @expected_transaction_event = nil
            raise 'abort_operation failed' unless status

            @root_group = nil
            @created_items = 0
            true
          end

          def close_open_operation_for_shutdown
            return unless @operation_open_assumed

            if @mode_plan&.transparent_slices?
              commit_open_operation
            else
              abort_open_operation
            end
          rescue StandardError => e
            puts "[WRITE UNDO PROTOTYPE] shutdown operation cleanup failed: #{e.class}: #{e.message}"
            @operation_open_assumed = false
          end

          def create_root_group
            group = @job_model.entities.add_group
            group.name = "#{GROUP_NAME_PREFIX} #{@run_id}"
            group.set_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_RUN_ID, @run_id)
            group.set_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_MODE, @mode_plan.mode.to_s)
            group.transformation = Geom::Transformation.translation(@base_point)
            group
          end

          def add_planned_edge(plan)
            raise 'probe root group is invalid' unless @root_group&.valid?

            @root_group.entities.add_line(plan[0], plan[1])
          end

          def build_item_plan(index)
            column_count = 50
            column = index % column_count
            row = index / column_count
            x = column * 1.0
            y = row * 1.0
            z = 0.0
            [[x, y, z], [x + 0.5, y, z]]
          end

          def choose_base_point(model)
            bounds = model.bounds
            max = bounds.max
            Geom::Point3d.new(max.x + 10.0, max.y, max.z)
          rescue StandardError
            Geom::Point3d.new(10.0, 0.0, 0.0)
          end

          def apply_runner_snapshot(snapshot)
            type = snapshot[:type] == :running ? :progress : snapshot[:type]
            @state.apply(
              type: type,
              total: snapshot[:total],
              completed: snapshot[:completed],
              percent: snapshot[:percent],
              elapsed: snapshot[:elapsed],
              message: progress_message(snapshot[:type]),
              count_label: @phase == :prepare ? '계획' : '생성',
              show_current_item_progress: false,
              mode: @mode_plan.mode,
              phase: @phase,
              slice_count: snapshot[:slice_count],
              last_slice_ms: snapshot[:last_slice_ms],
              max_slice_ms: snapshot[:max_slice_ms],
              overrun_count: snapshot[:overrun_count]
            )
          end

          def progress_message(type)
            return terminal_message(type) if ThreadedProgressInfrastructure::MainThreadSliceRunner::TERMINAL_TYPES.include?(type)

            case @mode_plan.mode
            when :prepare_then_apply
              '쓰기 계획 준비 중 — 아직 모델 변경 없음'
            when :held_operation
              '위험 실험: 열린 operation에서 분할 생성 중'
            when :transparent_slices
              '위험 실험: transparent operation chain 생성 중'
            end
          end

          def terminal_message(type)
            case type
            when :completed then 'Write/Undo probe 완료'
            when :cancelled then 'Write/Undo probe 취소됨'
            when :failed then 'Write/Undo probe 실패'
            else 'Write/Undo probe 종료'
            end
          end

          def finish_terminal(type)
            @phase = type
            stop_timer
            schedule_hide
          end

          def fail_job(error)
            puts "[WRITE UNDO PROTOTYPE] failed: #{error.class}: #{error.message}"
            if @operation_open_assumed
              if @mode_plan&.transparent_slices?
                commit_open_operation rescue nil
              else
                abort_open_operation rescue nil
              end
            end
            @phase = :failed
            @state.apply(
              type: :failed,
              error_message: "#{error.class}: #{error.message}",
              elapsed: elapsed,
              count_label: '생성',
              show_current_item_progress: false
            )
            invalidate_view
            finish_terminal(:failed)
          end

          def handle_model_change
            @runner&.cancel!
            if @operation_open_assumed && @job_model&.valid?
              if @mode_plan&.transparent_slices?
                commit_open_operation rescue nil
              else
                abort_open_operation rescue nil
              end
            end
            @rollback_status = :model_changed
            @state.apply(type: :failed, error_message: '작업 중 활성 모델이 변경되었습니다.')
            invalidate_view
            finish_terminal(:failed)
          end

          def transaction_event(type, model)
            return unless model.equal?(@job_model) || model.equal?(@observer_model)

            expected = @expected_transaction_event == type
            @transaction_events << {
              type: type,
              expected: expected,
              at: monotonic_time
            }.freeze
            if @mode_plan&.held_operation? && @operation_open_assumed && !expected && %i[commit abort].include?(type)
              @operation_interference = true
            end
          rescue StandardError => e
            puts "[WRITE UNDO PROTOTYPE] observer failed: #{e.class}: #{e.message}"
          end

          def attach_transaction_observer(model)
            return if @observer_model.equal?(model) && @observer

            detach_transaction_observer
            @observer = TransactionObserver.new { |type, observed_model| transaction_event(type, observed_model) }
            model.add_observer(@observer)
            @observer_model = model
          rescue StandardError => e
            puts "[WRITE UNDO PROTOTYPE] observer attach failed: #{e.class}: #{e.message}"
          end

          def detach_transaction_observer
            @observer_model&.remove_observer(@observer) if @observer_model && @observer
          rescue StandardError
            nil
          ensure
            @observer = nil
            @observer_model = nil
          end

          def current_group_snapshot
            groups = probe_groups(@job_model || Sketchup.active_model, @run_id)
            {
              group_count: groups.length,
              edge_count: groups.sum { |group| group.valid? ? group.entities.grep(Sketchup::Edge).length : 0 }
            }
          rescue StandardError
            { group_count: 0, edge_count: 0 }
          end

          def probe_groups(model, run_id)
            return [] unless model&.valid? && run_id

            model.entities.grep(Sketchup::Group).select do |group|
              group.valid? && group.get_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_RUN_ID) == run_id
            end
          end

          def all_probe_groups(model)
            return [] unless model&.valid?

            model.entities.grep(Sketchup::Group).select do |group|
              group.valid? && !group.get_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_RUN_ID).nil?
            end
          end

          def build_run_id
            "#{Time.now.strftime('%Y%m%d%H%M%S')}-#{object_id}-#{rand(1_000_000)}"
          end

          def elapsed
            @started_at ? monotonic_time - @started_at : 0.0
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
            puts "[WRITE UNDO PROTOTYPE] overlay registration failed: #{e.class}: #{e.message}"
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

          def close_other_prototypes
            MainThreadSlicePrototype.close! if defined?(MainThreadSlicePrototype)
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
            mode: :prepare_then_apply,
            item_count: DEFAULT_ITEM_COUNT,
            slice_budget_ms: DEFAULT_SLICE_BUDGET_MS,
            max_items_per_slice: DEFAULT_MAX_ITEMS_PER_SLICE,
            allow_risky: false
          )
            controller.start_job(
              mode: mode,
              item_count: item_count,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice,
              allow_risky: allow_risky
            )
          end

          def cancel!
            controller.cancel_job
          end

          def status!
            controller.status
          end

          def verify!(expected = :created)
            controller.verify(expected)
          end

          def undo!
            controller.undo
          end

          def redo!
            controller.redo
          end

          def cleanup!
            controller.cleanup
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

puts '[WRITE UNDO PROTOTYPE] installed'
puts 'Install : ...::WriteUndoPrototype.install!'
puts 'Safe    : ...::WriteUndoPrototype.start!'
puts 'Risky   : ...::WriteUndoPrototype.start!(mode: :held_operation, allow_risky: true)'
puts 'Status  : ...::WriteUndoPrototype.status!'
puts 'Verify  : ...::WriteUndoPrototype.verify!(:created)'
puts 'Undo    : ...::WriteUndoPrototype.undo!'
puts 'Redo    : ...::WriteUndoPrototype.redo!'
puts 'Cleanup : ...::WriteUndoPrototype.cleanup!'
puts 'Close   : ...::WriteUndoPrototype.close!'
