# frozen_string_literal: true

require_relative 'overlay_semantics_patch'
require_relative 'prepare_compute_apply_job'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrepareComputeApplyPrototype
        TIMER_INTERVAL = 0.01
        TERMINAL_HOLD_SECONDS = 2.0
        DEFAULT_ITEM_COUNT = 500
        DEFAULT_COMPUTE_WORK = 5_000
        ATTRIBUTE_DICTIONARY = 'ULOL_DEV_STAGED_JOB_PROBE'
        ATTRIBUTE_RUN_ID = 'run_id'
        GROUP_NAME_PREFIX = '[DEV] Prepare Compute Apply Probe'

        class InjectedApplyFailure < StandardError; end

        class Controller
          def initialize
            @main_thread = Thread.current
            @state = ThreadedProgressInfrastructure::OverlayState.new
            @overlay = nil
            @registered_model = nil
            @job_model = nil
            @job = nil
            @timer_id = nil
            @hide_timer_id = nil
            @root_group = nil
            @operation_open = false
            @run_id = nil
            @item_count = 0
            @compute_work = 0
            @fail_after_created_items = nil
            @created_items = 0
            @apply_ms = nil
            @rollback_status = :none
            @base_point = nil
          end

          def install
            assert_main_thread!
            close_other_prototypes
            ensure_registered(Sketchup.active_model)
            invalidate_view
            true
          end

          def start_job(
            item_count: DEFAULT_ITEM_COUNT,
            compute_work_per_item: DEFAULT_COMPUTE_WORK,
            slice_budget_ms: 8.0,
            max_items_per_slice: 50,
            fail_after_created_items: nil
          )
            assert_main_thread!
            return false if @job&.running?

            close_other_prototypes
            model = Sketchup.active_model
            return false unless ensure_registered(model)

            stop_timers
            reset_run_state
            @job_model = model
            @item_count = [item_count.to_i, 1].max
            @compute_work = [compute_work_per_item.to_i, 1].max
            @fail_after_created_items = normalize_failure_threshold(fail_after_created_items)
            @run_id = build_run_id
            @base_point = choose_base_point(model)

            @job = ThreadedProgressInfrastructure::PrepareComputeApplyJob.new(
              prepare_total: @item_count,
              prepare_step: method(:prepare_item),
              compute_step: method(:compute_item),
              apply_step: method(:apply_computed_items),
              rollback_step: method(:rollback_apply),
              finalize_step: method(:finalize_apply),
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice
            )
            @job.start
            apply_job_snapshot(@job.snapshot)
            invalidate_view
            start_timer
            true
          rescue StandardError => e
            puts "[STAGED JOB PROTOTYPE] start failed: #{e.class}: #{e.message}"
            false
          end

          def cancel_job
            assert_main_thread!
            return false unless @job

            @job.cancel!
            true
          end

          def status
            assert_main_thread!
            job_snapshot = @job&.snapshot || {}
            group_snapshot = current_group_snapshot
            snapshot = @state.snapshot.merge(
              job_type: job_snapshot[:type],
              phase: job_snapshot[:phase],
              phase_percent: job_snapshot[:phase_percent],
              overall_percent: job_snapshot[:overall_percent],
              prepare_count: job_snapshot[:prepare_count],
              compute_count: job_snapshot[:compute_count],
              prepare_slice_count: job_snapshot[:prepare_slice_count],
              prepare_max_slice_ms: job_snapshot[:prepare_max_slice_ms],
              prepare_overrun_count: job_snapshot[:prepare_overrun_count],
              worker_thread_id: job_snapshot[:worker_thread_id],
              worker_alive: job_snapshot[:worker_alive],
              rollback_attempted: job_snapshot[:rollback_attempted],
              rollback_result: job_snapshot[:rollback_result],
              error_class: job_snapshot[:error_class],
              error_message: job_snapshot[:error_message],
              run_id: @run_id,
              item_count: @item_count,
              compute_work_per_item: @compute_work,
              fail_after_created_items: @fail_after_created_items,
              created_items: @created_items,
              apply_ms: @apply_ms,
              rollback_status: @rollback_status,
              operation_open: @operation_open,
              group_count: group_snapshot[:group_count],
              edge_count: group_snapshot[:edge_count],
              current_thread_id: Thread.current.object_id,
              main_thread_id: @main_thread.object_id,
              timer_active: !@timer_id.nil?,
              overlay_valid: @overlay&.valid? == true,
              registered_model_id: @registered_model&.object_id
            )
            puts "[STAGED JOB PROTOTYPE] #{snapshot.inspect}"
            snapshot
          end

          def verify(expected = :created)
            assert_main_thread!
            expected = expected.to_sym
            group_snapshot = current_group_snapshot
            passed = case expected
                     when :created, :redone
                       group_snapshot[:group_count] == 1 && group_snapshot[:edge_count] == @item_count
                     when :undone, :rolled_back, :cancelled
                       group_snapshot[:group_count].zero? && group_snapshot[:edge_count].zero?
                     else
                       raise ArgumentError, "unsupported expected state: #{expected}"
                     end
            result = group_snapshot.merge(
              expected: expected,
              expected_edge_count: %i[created redone].include?(expected) ? @item_count : 0,
              passed: passed
            )
            puts "[STAGED JOB VERIFY] #{result.inspect}"
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
            return false if @job&.running?

            groups = all_probe_groups(Sketchup.active_model)
            return true if groups.empty?

            model = Sketchup.active_model
            model.start_operation('[DEV] Staged Job Probe Cleanup', true)
            model.entities.erase_entities(groups.select(&:valid?))
            model.commit_operation
            invalidate_view
            true
          rescue StandardError => e
            model.abort_operation rescue nil
            puts "[STAGED JOB PROTOTYPE] cleanup failed: #{e.class}: #{e.message}"
            false
          end

          def close
            assert_main_thread!
            @job&.cancel!
            abort_open_operation
            stop_timers
            @state.hide!
            invalidate_view
            unregister_overlay
            @job_model = nil
            true
          end

          private

          def reset_run_state
            @job = nil
            @root_group = nil
            @operation_open = false
            @run_id = nil
            @item_count = 0
            @compute_work = 0
            @fail_after_created_items = nil
            @created_items = 0
            @apply_ms = nil
            @rollback_status = :none
            @base_point = nil
            @state.reset!
          end

          def prepare_item(index)
            assert_main_thread!
            column_count = 50
            column = index % column_count
            row = index / column_count
            {
              index: index,
              start: [column.to_f, row.to_f, 0.0],
              length: 0.5
            }.freeze
          end

          def compute_item(input, index)
            value = (index + 1) & 0xFFFF_FFFF
            @compute_work.times do |iteration|
              value = ((value * 1_664_525) + 1_013_904_223 + iteration) & 0xFFFF_FFFF
            end
            offset = (value % 1000).fdiv(100_000.0)
            start = input.fetch(:start)
            x = start[0] + offset
            y = start[1]
            z = start[2]
            {
              index: input.fetch(:index),
              start: [x, y, z],
              finish: [x + input.fetch(:length), y, z],
              checksum: value
            }.freeze
          end

          def apply_computed_items(computed)
            assert_main_thread!
            started_at = monotonic_time
            begin_operation
            @root_group = create_root_group
            computed.each do |item|
              @root_group.entities.add_line(item.fetch(:start), item.fetch(:finish))
              @created_items += 1
              if @fail_after_created_items && @created_items >= @fail_after_created_items
                raise InjectedApplyFailure,
                      "injected staged apply failure after #{@created_items} created items"
              end
            end
            commit_open_operation
            @apply_ms = (monotonic_time - started_at) * 1000.0
            @rollback_status = :committed
            {
              created_items: @created_items,
              apply_ms: @apply_ms,
              run_id: @run_id
            }.freeze
          end

          def rollback_apply(_error, _apply_result, _computed)
            assert_main_thread!
            abort_open_operation
            @rollback_status = :aborted
            @created_items = 0
            @root_group = nil
            :aborted
          end

          def finalize_apply(apply_result, _computed)
            assert_main_thread!
            group_snapshot = current_group_snapshot
            {
              apply_result: apply_result,
              group_count: group_snapshot[:group_count],
              edge_count: group_snapshot[:edge_count],
              valid: group_snapshot[:group_count] == 1 && group_snapshot[:edge_count] == @item_count
            }.freeze
          end

          def begin_operation
            status = @job_model.start_operation('[DEV] Prepare Compute Apply Probe', true)
            raise 'start_operation failed' unless status

            @operation_open = true
          end

          def commit_open_operation
            return true unless @operation_open

            status = @job_model.commit_operation
            @operation_open = false
            raise 'commit_operation failed' unless status

            true
          end

          def abort_open_operation
            return true unless @operation_open

            status = @job_model.abort_operation
            @operation_open = false
            raise 'abort_operation failed' unless status

            true
          rescue StandardError => e
            puts "[STAGED JOB PROTOTYPE] abort failed: #{e.class}: #{e.message}"
            @operation_open = false
            false
          end

          def create_root_group
            group = @job_model.entities.add_group
            group.name = "#{GROUP_NAME_PREFIX} #{@run_id}"
            group.set_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_RUN_ID, @run_id)
            group.transformation = Geom::Transformation.translation(@base_point)
            group
          end

          def pump
            assert_main_thread!
            unless Sketchup.active_model.equal?(@job_model)
              @job&.cancel!
              @state.apply(type: :failed, error_message: '작업 중 활성 모델이 변경되었습니다.')
              stop_timer
              schedule_hide
              return false
            end

            snapshot = @job.tick
            apply_job_snapshot(snapshot)
            invalidate_view
            if snapshot[:terminal]
              stop_timer
              schedule_hide
            end
            true
          rescue StandardError => e
            puts "[STAGED JOB PROTOTYPE] pump failed: #{e.class}: #{e.message}"
            abort_open_operation
            @state.apply(type: :failed, error_message: "#{e.class}: #{e.message}")
            invalidate_view
            stop_timer
            schedule_hide
            false
          end

          def apply_job_snapshot(snapshot)
            phase = snapshot[:phase]
            type = snapshot[:type] == :running ? :progress : snapshot[:type]
            @state.apply(
              type: type,
              total: snapshot[:phase_total],
              completed: snapshot[:phase_completed],
              percent: snapshot[:overall_percent],
              elapsed: snapshot[:elapsed],
              message: message_for(phase, snapshot[:type]),
              count_label: count_label_for(phase),
              show_current_item_progress: false,
              phase: phase,
              phase_percent: snapshot[:phase_percent],
              overall_percent: snapshot[:overall_percent]
            )
          end

          def message_for(phase, type)
            return 'Prepare/Compute/Apply 작업 완료' if type == :completed
            return 'Prepare/Compute/Apply 작업 취소됨' if type == :cancelled
            return "Prepare/Compute/Apply 작업 실패: #{@job&.snapshot&.dig(:error_message)}" if type == :failed

            case phase
            when :prepare then 'Prepare: 메인 스레드에서 순수 입력 snapshot 준비 중'
            when :compute then 'Compute: worker thread에서 순수 Ruby 계산 중'
            when :apply then 'Apply: 메인 스레드 단일 operation 적용 중'
            when :finalize then 'Finalize: 결과 검증 및 정리 중'
            else 'Prepare/Compute/Apply 작업 준비 중'
            end
          end

          def count_label_for(phase)
            case phase
            when :prepare then '준비'
            when :compute then '계산'
            when :apply then '적용'
            when :finalize then '검증'
            else '진행'
            end
          end

          def start_timer
            stop_timer
            @timer_id = UI.start_timer(TIMER_INTERVAL, true) { pump }
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

          def schedule_hide
            stop_hide_timer
            @hide_timer_id = UI.start_timer(TERMINAL_HOLD_SECONDS, false) do
              @hide_timer_id = nil
              @state.hide!
              invalidate_view
              false
            end
          end

          def current_group_snapshot
            groups = probe_groups(@job_model || Sketchup.active_model, @run_id)
            {
              group_count: groups.length,
              edge_count: groups.sum do |group|
                group.valid? ? group.entities.grep(Sketchup::Edge).length : 0
              end
            }
          rescue StandardError
            { group_count: 0, edge_count: 0 }
          end

          def probe_groups(model, run_id)
            return [] unless model&.valid? && run_id

            model.entities.grep(Sketchup::Group).select do |group|
              group.valid? &&
                group.get_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_RUN_ID) == run_id
            end
          end

          def all_probe_groups(model)
            return [] unless model&.valid?

            model.entities.grep(Sketchup::Group).select do |group|
              group.valid? &&
                !group.get_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_RUN_ID).nil?
            end
          end

          def normalize_failure_threshold(value)
            return nil if value.nil?

            threshold = value.to_i
            threshold.positive? ? threshold : nil
          end

          def choose_base_point(model)
            max = model.bounds.max
            Geom::Point3d.new(max.x + 10.0, max.y, max.z)
          rescue StandardError
            Geom::Point3d.new(10.0, 0.0, 0.0)
          end

          def build_run_id
            "#{Time.now.strftime('%Y%m%d%H%M%S')}-#{object_id}-#{rand(1_000_000)}"
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
            puts "[STAGED JOB PROTOTYPE] overlay registration failed: #{e.class}: #{e.message}"
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
              next unless candidate.overlay_id ==
                          ThreadedProgressOverlayPrototype::ProgressOverlay::OVERLAY_ID

              stale << candidate
            end
            stale.each { |candidate| model.overlays.remove(candidate) }
          end

          def invalidate_view
            @registered_model&.active_view&.invalidate
          rescue StandardError
            nil
          end

          def close_other_prototypes
            WriteUndoPrototype.close! if defined?(WriteUndoPrototype)
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

          def start!(**options)
            controller.start_job(**options)
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

puts '[PREPARE COMPUTE APPLY PROTOTYPE] installed'
puts 'Install : ...::PrepareComputeApplyPrototype.install!'
puts 'Start   : ...::PrepareComputeApplyPrototype.start!'
puts 'Cancel  : ...::PrepareComputeApplyPrototype.cancel!'
puts 'Status  : ...::PrepareComputeApplyPrototype.status!'
puts 'Verify  : ...::PrepareComputeApplyPrototype.verify!(:created)'
puts 'Undo    : ...::PrepareComputeApplyPrototype.undo!'
puts 'Redo    : ...::PrepareComputeApplyPrototype.redo!'
puts 'Cleanup : ...::PrepareComputeApplyPrototype.cleanup!'
puts 'Close   : ...::PrepareComputeApplyPrototype.close!'
