# frozen_string_literal: true

require_relative 'adaptive_progress_checkpoint'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class RuntimeRefreshAdaptiveCheckpoint < AdaptiveProgressCheckpoint; end

        module RuntimeRefreshProgressContext
          THREAD_KEY = :ulol_indoor3d_runtime_refresh_progress

          module_function

          def current
            Thread.current[THREAD_KEY]
          end

          def with(tracker)
            previous = Thread.current[THREAD_KEY]
            Thread.current[THREAD_KEY] = tracker
            yield
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end

        class RuntimeRefreshProgressTracker
          attr_reader :session, :metrics

          def initialize(session, logger: IndoorCore::Logger, clock: nil)
            @session = session
            @logger = logger
            @clock = clock || proc { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            @stage_open = false
            @stage_name = nil
            @stage_started_at = nil
            @stage_total = 0
            @stage_completed = 0
            @checkpoint = nil
            @phase = nil
            @metrics = {}
          end

          def active?
            @session&.active? == true
          end

          def phase?(value)
            @phase == value
          end

          def with_phase(value)
            previous = @phase
            @phase = value
            yield
          ensure
            @phase = previous
          end

          def start_stage(name, total:, message:)
            return false unless active?

            finish_open_stage
            @stage_name = name.to_s
            @stage_total = [total.to_i, 0].max
            @stage_completed = 0
            @checkpoint = RuntimeRefreshAdaptiveCheckpoint.new(@stage_total)
            @stage_started_at = now
            @session.start_stage(
              @stage_name,
              total: @stage_total,
              message: message.to_s,
              cancellable: false,
              metadata: { source: :runtime_refresh }
            )
            @stage_open = true
            true
          rescue StandardError => e
            log_error('start stage', e)
            reset_stage
            false
          end

          def advance(message: nil, telemetry: nil)
            return false unless @stage_open && active?

            @stage_completed = [@stage_completed + 1, @stage_total].min
            return true unless @checkpoint&.checkpoint?(@stage_completed)

            @session.update_stage(
              completed: @stage_completed,
              message: message,
              telemetry: telemetry
            )
            true
          rescue StandardError => e
            log_error('advance stage', e)
            false
          end

          def finish_open_stage(message: nil, telemetry: nil)
            return false unless @stage_open
            return reset_stage unless active?

            duration = @stage_started_at ? now - @stage_started_at : 0.0
            @metrics[metric_key(@stage_name)] = duration
            @session.finish_stage(
              message: message || "#{@stage_name} 완료",
              telemetry: merge_duration(telemetry, duration)
            )
            reset_stage
            true
          rescue StandardError => e
            log_error('finish stage', e)
            reset_stage
            false
          end

          def with_adjacency_progress
            finish_open_stage
            return yield unless active?
            return yield unless defined?(AdjacencyProgressSink) && defined?(AdjacencyProgressContext)

            sink = AdjacencyProgressSink.new(@session, logger: @logger)
            result = AdjacencyProgressContext.with(sink) { yield }
            sink.finish_open_stage(
              message: 'Adjacency/Transition 재구축 완료',
              telemetry: result.respond_to?(:to_h) ? result.to_h : nil
            )
            result
          rescue StandardError => e
            log_error('adjacency progress', e)
            raise
          end

          private

          def reset_stage
            @stage_open = false
            @stage_name = nil
            @stage_started_at = nil
            @stage_total = 0
            @stage_completed = 0
            @checkpoint = nil
            false
          end

          def merge_duration(telemetry, duration)
            values = telemetry ? telemetry.to_h.dup : {}
            values[:duration] = duration
            values
          rescue StandardError
            { duration: duration }
          end

          def metric_key(name)
            name.to_s.gsub(/[^0-9A-Za-z가-힣]+/, '_').gsub(/\A_|_\z/, '').to_sym
          end

          def now
            @clock.call.to_f
          end

          def log_error(context, error)
            @logger.puts(
              "[IndoorGML] Runtime refresh progress #{context} failed: #{error.class}: #{error.message}"
            )
          rescue StandardError
            nil
          end
        end

        # Runtime refresh stages are immediately followed by another stage. Avoid
        # rendering an intermediate completed frame before the next phase starts.
        class RuntimeRefreshProgressRenderer < SketchupOverlayProgressRenderer
          def update(snapshot)
            return true if defer_intermediate_completion?(snapshot)

            super
          end

          private

          def defer_intermediate_completion?(snapshot)
            return false unless snapshot.respond_to?(:[])
            return false if snapshot[:terminal] == true

            stage = snapshot[:stage]
            return false unless stage.respond_to?(:[])

            status = stage[:status].to_sym
            return true if status == :completed

            total = stage[:total].to_i
            completed = stage[:completed].to_i
            total.positive? && completed >= total
          rescue StandardError
            false
          end
        end

        module RuntimeRestorerProgressIntegration
          def restore(primal_group:, persist_repaired_ids: false)
            tracker = RuntimeRefreshProgressContext.current
            return super unless tracker&.active?

            cell_count = runtime_refresh_cell_count(primal_group)
            tracker.start_stage(
              'Runtime 데이터 복원',
              total: cell_count * 2,
              message: "CellSpace/State 복원: 0 / #{cell_count * 2}"
            )
            result = super
            tracker.finish_open_stage(
              message: "Runtime 데이터 복원 완료: #{cell_count}개 CellSpace"
            )
            result
          end

          private

          def restore_cell_space(entity)
            result = super
            runtime_refresh_advance_restore
            result
          end

          def restore_state(cell_space)
            result = super
            runtime_refresh_advance_restore
            result
          end

          def runtime_refresh_advance_restore
            tracker = RuntimeRefreshProgressContext.current
            return unless tracker&.active?

            tracker.advance(message: 'CellSpace/State Runtime 복원 중')
          end

          def runtime_refresh_cell_count(primal_group)
            return 0 unless primal_group&.valid?

            indoor_children(primal_group.entities, 'CellSpace').length
          rescue StandardError
            0
          end
        end

        module IndoorModelRuntimeRefreshProgressIntegration
          def refresh_runtime_data(initial_model_load: false)
            unless runtime_refresh_progress_applicable?(initial_model_load)
              return super
            end

            session = build_runtime_refresh_progress_session(initial_model_load)
            return super unless session

            tracker = RuntimeRefreshProgressTracker.new(
              session,
              logger: IndoorCore::Logger
            )
            session.start(message: 'IndoorGML Runtime 준비 중')
            result = RuntimeRefreshProgressContext.with(tracker) do
              super
            end
            tracker.finish_open_stage
            session.complete(
              message: "IndoorGML Runtime 준비 완료: #{@cell_spaces.length}개 CellSpace",
              telemetry: {
                cell_spaces: @cell_spaces.length,
                states: @states.length,
                transitions: @transitions.length,
                stages: tracker.metrics
              }
            ) if session.active?
            result
          rescue StandardError => e
            report_runtime_refresh_progress_failure(session, e)
            raise
          ensure
            close_runtime_refresh_progress(session)
          end

          private

          def prepare_primal_children_for_initial_load
            tracker = RuntimeRefreshProgressContext.current
            return super unless tracker&.active?

            tracker.start_stage(
              'IndoorGML 모델 구조 확인',
              total: 1,
              message: 'PrimalSpaceFeatures 구조 확인 중'
            )
            result = super
            tracker.advance(message: 'IndoorGML 모델 구조 확인 완료')
            tracker.finish_open_stage(message: 'IndoorGML 모델 구조 확인 완료')
            result
          end

          def recenter_runtime_cell_spaces
            tracker = RuntimeRefreshProgressContext.current
            return super unless tracker&.active?

            total = runtime_refresh_valid_cell_count
            tracker.start_stage(
              'CellSpace 위치 정리',
              total: total,
              message: "CellSpace 위치 정리: 0 / #{total}"
            )
            result = tracker.with_phase(:recenter) { super }
            tracker.finish_open_stage(message: "CellSpace 위치 정리 완료: #{total}개")
            result
          end

          def write_cell_space_attributes(cell_space)
            result = super
            tracker = RuntimeRefreshProgressContext.current
            if tracker&.active? && tracker.phase?(:recenter)
              tracker.advance(message: 'CellSpace 위치/속성 정리 중')
            end
            result
          end

          def apply_initial_cell_space_materials
            tracker = RuntimeRefreshProgressContext.current
            return super unless tracker&.active?

            total = runtime_refresh_valid_cell_count
            tracker.start_stage(
              'CellSpace 재질 적용',
              total: total,
              message: "CellSpace 재질 적용: 0 / #{total}"
            )
            result = tracker.with_phase(:material) { super }
            tracker.finish_open_stage(message: "CellSpace 재질 적용 완료: #{total}개")
            result
          end

          def apply_cell_space_material(cell_space)
            result = super
            tracker = RuntimeRefreshProgressContext.current
            if tracker&.active? && tracker.phase?(:material)
              tracker.advance(message: 'CellSpace 재질 적용 중')
            end
            result
          end

          def rebuild_runtime_transitions_from_cell_adjacency
            tracker = RuntimeRefreshProgressContext.current
            return super unless tracker&.active?

            tracker.with_adjacency_progress { super }
          end

          def runtime_refresh_progress_applicable?(_initial_model_load)
            return false if RuntimeRefreshProgressContext.current&.active?
            return false if instance_variable_get(:@refreshing_runtime) == true

            model = @model || (defined?(Sketchup) ? Sketchup.active_model : nil)
            return false unless model&.respond_to?(:entities)

            model.entities.to_a.any? { |entity| runtime_refresh_primal_entity?(entity) }
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Runtime refresh progress detection failed: #{e.class}: #{e.message}"
            )
            false
          end

          def runtime_refresh_primal_entity?(entity)
            return false if entity.nil?
            return false if entity.respond_to?(:valid?) && !entity.valid?

            return true if entity.respond_to?(:name) && entity.name.to_s == IndoorModel::PRIMAL_GROUP_NAME
            return false unless entity.respond_to?(:get_attribute)

            entity.get_attribute(
              IndoorModel::ATTRIBUTE_DICTIONARY_NAME,
              'feature'
            ).to_s == IndoorModel::PRIMAL_GROUP_FEATURE
          rescue StandardError
            false
          end

          def runtime_refresh_valid_cell_count
            Array(@cell_spaces).count do |cell_space|
              cell_space.respond_to?(:valid?) ? cell_space.valid? : !cell_space.nil?
            rescue StandardError
              false
            end
          end

          def build_runtime_refresh_progress_session(initial_model_load)
            model = @model || Sketchup.active_model
            stage_count = initial_model_load == true ? 6 : 4
            ProductionProgressSession.new(
              title: initial_model_load == true ? 'IndoorGML 모델 열기' : 'IndoorGML Runtime Refresh',
              total: stage_count,
              renderer: RuntimeRefreshProgressRenderer.new(model: model),
              cancellable: false,
              metadata: {
                operation: :runtime_refresh,
                initial_model_load: initial_model_load == true,
                stage_count: stage_count,
                model_object_id: model&.object_id
              }
            )
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Runtime refresh progress start failed: #{e.class}: #{e.message}"
            )
            nil
          end

          def report_runtime_refresh_progress_failure(session, error)
            return unless session&.active?

            session.fail(error, message: "IndoorGML Runtime 준비 실패: #{error.message}")
          rescue StandardError => progress_error
            IndoorCore::Logger.puts(
              "[IndoorGML] Runtime refresh progress failure reporting failed: " \
              "#{progress_error.class}: #{progress_error.message}"
            )
          end

          def close_runtime_refresh_progress(session)
            session&.close
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Runtime refresh progress close failed: #{e.class}: #{e.message}"
            )
            false
          end
        end
      end

      if defined?(RuntimeRestorer)
        RuntimeRestorer.prepend(
          ProductionProgress::RuntimeRestorerProgressIntegration
        ) unless RuntimeRestorer.ancestors.include?(
          ProductionProgress::RuntimeRestorerProgressIntegration
        )
      end

      if defined?(IndoorModel)
        IndoorModel.prepend(
          ProductionProgress::IndoorModelRuntimeRefreshProgressIntegration
        ) unless IndoorModel.ancestors.include?(
          ProductionProgress::IndoorModelRuntimeRefreshProgressIntegration
        )
      end
    end
  end
end
