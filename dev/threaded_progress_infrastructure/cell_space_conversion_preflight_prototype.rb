# frozen_string_literal: true

require_relative 'overlay_semantics_patch'
require_relative 'cell_space_conversion_preflight_adapter'
require_relative 'bulk_cell_space_conversion_preflight_session'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionPreflightPrototype
        TIMER_INTERVAL = 0.01
        TERMINAL_HOLD_SECONDS = 2.0

        class Controller
          def initialize
            @main_thread = Thread.current
            @state = ThreadedProgressInfrastructure::OverlayState.new
            @overlay = nil
            @registered_model = nil
            @job_model = nil
            @session = nil
            @timer_id = nil
            @hide_timer_id = nil
            @jobs = [].freeze
            @sources = [].freeze
            @source_snapshot = [].freeze
            @root_entity_count = nil
            @fallback_target = nil
            @result_errors = [].freeze
          end

          def install
            assert_main_thread!
            close_other_prototypes
            ensure_registered(Sketchup.active_model)
            invalidate_view
            true
          end

          def start_job(
            fallback_cell_type: CellSpaceType::GENERAL,
            fallback_category_code: nil,
            slice_budget_ms: 8.0,
            max_items_per_slice: 25
          )
            assert_main_thread!
            return false if @session&.running?

            close_other_prototypes
            model = Sketchup.active_model
            return false unless ensure_registered(model)

            stop_timers
            reset_run_state
            @job_model = model
            @fallback_target = [fallback_cell_type, fallback_category_code].freeze
            selected = model.selection.to_a.select { |entity| convertible_container?(entity) }
            @jobs = CellSpaceConversionJobBuilder.new(entities: selected).build.freeze
            @sources = @jobs.map { |job| job[:source] }.compact.uniq.freeze
            @source_snapshot = capture_source_snapshot(@sources)
            @root_entity_count = model.entities.length

            service = build_preflight_service(model, @jobs, @fallback_target)
            adapter = ThreadedProgressInfrastructure::CellSpaceConversionPreflightAdapter.new(service)
            @session = ThreadedProgressInfrastructure::BulkCellSpaceConversionPreflightSession.new(
              jobs: @jobs,
              adapter: adapter,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice,
              predictive_budget: true
            )
            @session.start
            apply_session_snapshot(@session.snapshot)
            invalidate_view
            start_timer
            true
          rescue StandardError => e
            puts "[CELLSPACE PREFLIGHT PROTOTYPE] start failed: #{e.class}: #{e.message}"
            @state.apply(type: :failed, error_message: "#{e.class}: #{e.message}")
            invalidate_view
            false
          end

          def cancel_job
            assert_main_thread!
            return false unless @session

            @session.cancel!
            true
          end

          def status
            assert_main_thread!
            session_snapshot = @session&.snapshot || {}
            snapshot = @state.snapshot.merge(
              session_type: session_snapshot[:type],
              stage: session_snapshot[:stage],
              stage_percent: session_snapshot[:stage_percent],
              overall_percent: session_snapshot[:overall_percent],
              job_count: @jobs.length,
              source_count: @sources.length,
              plan_count: session_snapshot[:plan_count].to_i,
              error_count: session_snapshot[:error_count].to_i,
              errors: @result_errors,
              fallback_target: @fallback_target,
              predictive_budget: session_snapshot[:predictive_budget],
              predictive_stop_count: session_snapshot[:predictive_stop_count],
              max_slice_ms: session_snapshot[:max_slice_ms],
              overrun_count: session_snapshot[:overrun_count],
              max_item_ms: session_snapshot[:max_item_ms],
              current_thread_id: Thread.current.object_id,
              main_thread_id: @main_thread.object_id,
              timer_active: !@timer_id.nil?,
              overlay_valid: @overlay&.valid? == true,
              registered_model_id: @registered_model&.object_id
            ).freeze
            puts "[CELLSPACE PREFLIGHT PROTOTYPE] #{snapshot.inspect}"
            snapshot
          end

          def verify
            assert_main_thread!
            model = @job_model || Sketchup.active_model
            current_snapshot = capture_source_snapshot(@sources)
            result = {
              root_entity_count_before: @root_entity_count,
              root_entity_count_after: model&.valid? ? model.entities.length : nil,
              root_entity_count_unchanged: model&.valid? && model.entities.length == @root_entity_count,
              source_snapshot_unchanged: current_snapshot == @source_snapshot,
              sources_still_valid: @sources.all? { |source| source&.valid? },
              operation_started: false,
              passed: false
            }
            result[:passed] = result[:root_entity_count_unchanged] &&
                              result[:source_snapshot_unchanged] &&
                              result[:sources_still_valid]
            result.freeze.tap do |payload|
              puts "[CELLSPACE PREFLIGHT VERIFY] #{payload.inspect}"
            end
          end

          def close
            assert_main_thread!
            @session&.cancel!
            stop_timers
            @state.hide!
            invalidate_view
            unregister_overlay
            @job_model = nil
            true
          end

          private

          def reset_run_state
            @session = nil
            @jobs = [].freeze
            @sources = [].freeze
            @source_snapshot = [].freeze
            @root_entity_count = nil
            @fallback_target = nil
            @result_errors = [].freeze
            @state.reset!
          end

          def build_preflight_service(model, jobs, fallback_target)
            BulkCellSpaceConversionService.new(
              model: model,
              jobs: jobs,
              fallback_target: fallback_target,
              target_entities: model.entities,
              converter: proc { raise 'preflight prototype must not call converter' },
              synchronize_all: proc { raise 'preflight prototype must not synchronize topology' },
              apply_lock_policy: proc { raise 'preflight prototype must not apply lock policy' },
              runtime_snapshot: proc { raise 'preflight prototype must not capture apply runtime' },
              runtime_restore: proc { raise 'preflight prototype must not restore apply runtime' },
              apply_guards: proc { raise 'preflight prototype must not enter apply guards' },
              operation_runner: proc { raise 'preflight prototype must not start an operation' },
              restore_active_path: proc { raise 'preflight prototype must not restore active path' },
              activate_root_context: proc { raise 'preflight prototype must not activate root context' },
              clear_dirty_topology: proc { raise 'preflight prototype must not clear topology' },
              logger: IndoorCore::Logger,
              labeler: ConversionMessageFormatter.method(:group_label),
              preserve_source: proc { |_source| true },
              operation_name: '[DEV] CellSpace Conversion Preflight'
            )
          end

          def capture_source_snapshot(sources)
            Array(sources).map do |source|
              {
                object_id: source.object_id,
                entity_id: safe_entity_id(source),
                valid: source&.valid? == true,
                name: safe_name(source),
                feature: safe_feature(source)
              }.freeze
            end.freeze
          end

          def safe_entity_id(entity)
            entity.entityID if entity&.respond_to?(:entityID)
          rescue StandardError
            nil
          end

          def safe_name(entity)
            entity.name.to_s if entity&.respond_to?(:name)
          rescue StandardError
            ''
          end

          def safe_feature(entity)
            entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
          rescue StandardError
            nil
          end

          def convertible_container?(entity)
            entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          end

          def pump
            assert_main_thread!
            unless Sketchup.active_model.equal?(@job_model)
              @session&.cancel!
              @state.apply(type: :failed, error_message: '사전검사 중 활성 모델이 변경되었습니다.')
              stop_timer
              schedule_hide
              return false
            end

            snapshot = @session.tick
            apply_session_snapshot(snapshot)
            invalidate_view
            if snapshot[:terminal]
              @result_errors = @session.errors.freeze
              stop_timer
              schedule_hide
            end
            true
          rescue StandardError => e
            puts "[CELLSPACE PREFLIGHT PROTOTYPE] pump failed: #{e.class}: #{e.message}"
            @state.apply(type: :failed, error_message: "#{e.class}: #{e.message}")
            invalidate_view
            stop_timer
            schedule_hide
            false
          end

          def apply_session_snapshot(snapshot)
            type = snapshot[:type] == :running ? :progress : snapshot[:type]
            @state.apply(
              type: type,
              total: snapshot[:stage_total],
              completed: snapshot[:stage_completed],
              percent: snapshot[:overall_percent],
              elapsed: snapshot[:elapsed],
              message: message_for(snapshot[:stage], snapshot[:type]),
              count_label: count_label_for(snapshot[:stage]),
              show_current_item_progress: false,
              stage: snapshot[:stage],
              stage_percent: snapshot[:stage_percent],
              overall_percent: snapshot[:overall_percent]
            )
          end

          def message_for(stage, type)
            return 'CellSpace 변환 사전검사 완료' if type == :completed
            return 'CellSpace 변환 사전검사 취소됨' if type == :cancelled
            return "CellSpace 변환 사전검사 실패: #{@session&.snapshot&.dig(:error_message)}" if type == :failed

            case stage
            when :prepare then 'CellSpace 변환 작업 준비 중'
            when :geometry then 'CellSpace source geometry 검사 중'
            when :target then 'CellSpace type/category 대상 검사 중'
            else 'CellSpace 변환 사전검사 준비 중'
            end
          end

          def count_label_for(stage)
            case stage
            when :prepare then '준비'
            when :geometry then '형상 검사'
            when :target then '대상 검사'
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
            puts "[CELLSPACE PREFLIGHT PROTOTYPE] overlay registration failed: #{e.class}: #{e.message}"
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
            PrepareComputeApplyPrototype.close! if defined?(PrepareComputeApplyPrototype)
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

          def verify!
            controller.verify
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

puts '[CELLSPACE CONVERSION PREFLIGHT PROTOTYPE] installed'
puts 'Install: ...::CellSpaceConversionPreflightPrototype.install!'
puts 'Start  : ...::CellSpaceConversionPreflightPrototype.start!'
puts 'Cancel : ...::CellSpaceConversionPreflightPrototype.cancel!'
puts 'Status : ...::CellSpaceConversionPreflightPrototype.status!'
puts 'Verify : ...::CellSpaceConversionPreflightPrototype.verify!'
puts 'Close  : ...::CellSpaceConversionPreflightPrototype.close!'
