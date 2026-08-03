# frozen_string_literal: true

require_relative '../../export/gml_exporter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class GmlExportAdaptiveCheckpoint
          TARGET_UPDATES = 100

          def initialize(total, target_updates: TARGET_UPDATES)
            @total = [total.to_i, 0].max
            @target_updates = [target_updates.to_i, 1].max
            @step = adaptive_step(@total)
          end

          def checkpoint?(completed)
            completed = completed.to_i
            return false if completed <= 0 || @total <= 0
            return true if completed == 1 || completed >= @total

            (completed % @step).zero?
          end

          private

          def adaptive_step(total)
            raw_step = [(total.to_f / @target_updates).ceil, 1].max
            magnitude = 1
            magnitude *= 10 while raw_step > magnitude * 10
            normalized = raw_step.fdiv(magnitude)
            factor = if normalized <= 1.0
                       1
                     elsif normalized <= 2.0
                       2
                     elsif normalized <= 5.0
                       5
                     else
                       10
                     end
            factor * magnitude
          end
        end

        module GmlExportInvocationContext
          THREAD_KEY = :ulol_indoor3d_gml_export_invocation

          module_function

          def current
            Thread.current[THREAD_KEY]
          end

          def with(invocation)
            previous = Thread.current[THREAD_KEY]
            Thread.current[THREAD_KEY] = invocation
            yield
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end

        module GmlExportProgressContext
          THREAD_KEY = :ulol_indoor3d_gml_export_progress

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

        class ProductionGmlExportProgressAdapter
          def initialize(model:, logger: IndoorCore::Logger)
            @logger = logger
            @session = build_session(model)
          end

          def available?
            !@session.nil?
          end

          def active?
            @session&.active? == true
          end

          def start(message:)
            @session.start(message: message)
          end

          def start_stage(name:, total:, message:, stage_index:, stage_count:)
            @session.start_stage(
              name,
              total: total,
              message: message,
              cancellable: false,
              metadata: {
                source: :gml_export,
                stage_index: stage_index,
                stage_count: stage_count
              }
            )
          end

          def update_stage(completed:, message:, telemetry: nil, **_unused)
            @session.update_stage(
              completed: completed,
              message: message,
              telemetry: telemetry
            )
          end

          def finish_stage(message:, telemetry: nil, **_unused)
            @session.finish_stage(message: message, telemetry: telemetry)
          end

          def complete(message:, telemetry: nil)
            @session.complete(message: message, telemetry: telemetry)
          end

          def fail(error, message:)
            @session.fail(error, message: message)
          end

          def close
            @session&.close
          end

          private

          def build_session(model)
            return nil unless defined?(ProductionProgressSession)
            return nil unless defined?(SketchupOverlayProgressRenderer)

            ProductionProgressSession.new(
              title: 'IndoorGML GML Export',
              total: GmlExportProgressTracker::STAGES.length,
              renderer: SketchupOverlayProgressRenderer.new(model: model),
              cancellable: false,
              metadata: {
                operation: :gml_export,
                model_object_id: model&.object_id
              }
            )
          rescue StandardError => e
            @logger.puts(
              "[IndoorGML] GML export overlay start failed: #{e.class}: #{e.message}"
            )
            nil
          end
        end

        class ValidationGmlExportProgressAdapter
          def initialize(progress:, step: :temp_file)
            @progress = progress
            @step = step
          end

          def available?
            !@progress.nil? && @progress.respond_to?(:detail)
          end

          def active?
            available?
          end

          def start(message:)
            detail(percent: 0, phase: 'GML export', message: message)
          end

          def start_stage(name:, total:, message:, stage_index:, stage_count:)
            @stage_index = stage_index
            @stage_count = [stage_count.to_i, 1].max
            @stage_total = [total.to_i, 0].max
            detail(
              percent: overall_percent(0),
              phase: name,
              message: message
            )
          end

          def update_stage(completed:, message:, stage_index:, stage_count:, total:, **_unused)
            @stage_index = stage_index
            @stage_count = [stage_count.to_i, 1].max
            @stage_total = [total.to_i, 0].max
            detail(
              percent: overall_percent(completed),
              phase: nil,
              message: message
            )
          end

          def finish_stage(message:, stage_index:, stage_count:, **_unused)
            @stage_index = stage_index
            @stage_count = [stage_count.to_i, 1].max
            detail(
              percent: (((stage_index + 1).to_f / @stage_count) * 100.0).round,
              phase: nil,
              message: message
            )
          end

          def complete(message:, telemetry: nil)
            detail(percent: 100, phase: 'GML export 완료', message: message)
          end

          def fail(_error, message:)
            detail(percent: current_percent, phase: 'GML export 실패', message: message)
          end

          def close
            true
          end

          private

          def detail(percent:, phase:, message:)
            options = {
              percent: [[percent.to_i, 0].max, 100].min,
              message: message.to_s
            }
            options[:phase] = phase.to_s unless phase.nil?
            @progress.detail(@step, **options)
            true
          rescue StandardError
            false
          end

          def overall_percent(completed)
            stage_fraction = if @stage_total.to_i <= 0
                               0.0
                             else
                               [[completed.to_f / @stage_total, 0.0].max, 1.0].min
                             end
            (((@stage_index.to_i + stage_fraction) / @stage_count.to_f) * 100.0).round
          end

          def current_percent
            (((@stage_index.to_i) / [@stage_count.to_i, 1].max.to_f) * 100.0).round
          end
        end

        class GmlExportProgressTracker
          STAGES = [
            'CellSpace Geometry 추출',
            'State/Transition 구성',
            'Export 내용 검증',
            'GML 구조 생성',
            'XML 변환 및 파일 저장'
          ].freeze

          attr_reader :metrics

          def initialize(adapter, logger: IndoorCore::Logger, clock: nil)
            @adapter = adapter
            @logger = logger
            @clock = clock || proc { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            @metrics = {}
            reset_stage
          end

          def available?
            @adapter&.available? == true
          end

          def active?
            @adapter&.active? == true
          end

          def start(message: 'IndoorGML GML Export 준비 중')
            return false unless available?

            @adapter.start(message: message)
            true
          rescue StandardError => e
            log_error('start', e)
            false
          end

          def start_stage(name, total:, message:)
            return false unless active?

            finish_open_stage if @stage_open
            @stage_name = name.to_s
            @stage_index = STAGES.index(@stage_name) || 0
            @stage_total = [total.to_i, 0].max
            @stage_completed = 0
            @checkpoint = GmlExportAdaptiveCheckpoint.new(@stage_total)
            @stage_started_at = now
            @adapter.start_stage(
              name: @stage_name,
              total: @stage_total,
              message: message.to_s,
              stage_index: @stage_index,
              stage_count: STAGES.length
            )
            @stage_open = true
            true
          rescue StandardError => e
            log_error('start stage', e)
            reset_stage
            false
          end

          def advance(by: 1, message: nil, telemetry: nil)
            return false unless @stage_open && active?

            increment = [by.to_i, 0].max
            @stage_completed = [@stage_completed + increment, @stage_total].min
            should_update = increment > 1 ||
                            @checkpoint&.checkpoint?(@stage_completed)
            return true unless should_update

            @adapter.update_stage(
              completed: @stage_completed,
              total: @stage_total,
              message: message,
              telemetry: telemetry,
              stage_index: @stage_index,
              stage_count: STAGES.length
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
            @adapter.finish_stage(
              message: message || "#{@stage_name} 완료",
              telemetry: merge_duration(telemetry, duration),
              stage_index: @stage_index,
              stage_count: STAGES.length,
              total: @stage_total,
              completed: @stage_completed
            )
            reset_stage
            true
          rescue StandardError => e
            log_error('finish stage', e)
            reset_stage
            false
          end

          def complete(message:, telemetry: nil)
            finish_open_stage if @stage_open
            @adapter.complete(message: message, telemetry: telemetry)
            true
          rescue StandardError => e
            log_error('complete', e)
            false
          end

          def fail(error, message:)
            @adapter.fail(error, message: message) if @adapter
            true
          rescue StandardError => e
            log_error('fail', e)
            false
          end

          def close
            @adapter&.close
          rescue StandardError => e
            log_error('close', e)
            false
          end

          private

          def reset_stage
            @stage_open = false
            @stage_name = nil
            @stage_index = 0
            @stage_total = 0
            @stage_completed = 0
            @checkpoint = nil
            @stage_started_at = nil
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
              "[IndoorGML] GML export progress #{context} failed: " \
              "#{error.class}: #{error.message}"
            )
          rescue StandardError
            nil
          end
        end

        module ExportCommandsProgressIntegration
          def export_runtime_gml(indoor_model, progress = nil)
            invocation = {
              mode: progress ? :validation : :production,
              progress: progress,
              step: :temp_file,
              indoor_model: indoor_model
            }
            GmlExportInvocationContext.with(invocation) { super }
          end

          def start_temp_file_creation(session, output_path: nil, step: :temp_file)
            invocation = {
              mode: :validation,
              progress: session&.progress,
              step: step,
              indoor_model: session&.indoor_model
            }
            GmlExportInvocationContext.with(invocation) do
              super
            end
          end
        end

        module GmlExporterProgressIntegration
          def export(*arguments, **keywords)
            invocation = GmlExportInvocationContext.current
            return super unless invocation
            return super if GmlExportProgressContext.current&.active?

            tracker = build_gml_export_progress_tracker(invocation)
            return super unless tracker&.available?

            tracker.start
            result = GmlExportProgressContext.with(tracker) do
              super
            end
            tracker.complete(
              message: 'IndoorGML GML Export 완료',
              telemetry: gml_export_progress_telemetry(tracker)
            )
            result
          rescue StandardError => e
            tracker&.fail(e, message: "IndoorGML GML Export 실패: #{e.message}")
            raise
          ensure
            tracker&.close
          end

          private

          def validate_exportable_content!
            tracker = GmlExportProgressContext.current
            return super unless tracker&.active?

            tracker.start_stage(
              'Export 내용 검증',
              total: 1,
              message: 'Export 가능한 CellSpace와 navigation semantics 확인 중'
            )
            result = super
            tracker.advance(message: 'Export 내용 검증 완료')
            tracker.finish_open_stage(message: 'Export 내용 검증 완료')
            result
          end

          def measure_export_step(label, &block)
            result = super
            tracker = GmlExportProgressContext.current
            if tracker&.active? && label.to_s == 'write GML file'
              tracker.advance(message: 'GML 파일 저장 완료')
              tracker.finish_open_stage(message: 'XML 변환 및 GML 파일 저장 완료')
            end
            result
          end

          def build_gml_export_progress_tracker(invocation)
            adapter = if invocation[:mode] == :validation
                        ValidationGmlExportProgressAdapter.new(
                          progress: invocation[:progress],
                          step: invocation[:step] || :temp_file
                        )
                      else
                        model = @indoor_model&.model ||
                                (defined?(Sketchup) ? Sketchup.active_model : nil)
                        ProductionGmlExportProgressAdapter.new(model: model)
                      end
            GmlExportProgressTracker.new(adapter)
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] GML export progress tracker setup failed: " \
              "#{e.class}: #{e.message}"
            )
            nil
          end

          def gml_export_progress_telemetry(tracker)
            snapshot = instance_variable_get(:@export_snapshot)
            {
              cell_spaces: snapshot&.cell_spaces&.length.to_i,
              transitions: snapshot&.transitions&.length.to_i,
              stages: tracker.metrics
            }
          rescue StandardError
            { stages: tracker.metrics }
          end
        end

        module ExportSnapshotBuilderProgressIntegration
          def build
            tracker = GmlExportProgressContext.current
            return super unless tracker&.active?

            cells = exportable_cell_spaces
            @gml_export_transition_stage_started = false
            tracker.start_stage(
              'CellSpace Geometry 추출',
              total: cells.length,
              message: "CellSpace Geometry 추출: 0 / #{cells.length}"
            )
            result = super
            unless @gml_export_transition_stage_started
              tracker.finish_open_stage(
                message: "CellSpace Geometry 추출 완료: #{cells.length}개"
              )
              tracker.start_stage(
                'State/Transition 구성',
                total: 0,
                message: 'State/Transition 구성 대상 없음'
              )
            end
            tracker.finish_open_stage(message: 'State/Transition 구성 완료')
            result
          ensure
            @gml_export_transition_stage_started = false
          end

          private

          def build_cell_space_snapshot(cell_space)
            result = super
            tracker = GmlExportProgressContext.current
            tracker&.advance(message: 'CellSpace Face/Ring 좌표 추출 중') if tracker&.active?
            result
          end

          def exportable_transitions(cell_snapshots_by_source)
            result = super
            tracker = GmlExportProgressContext.current
            if tracker&.active?
              tracker.finish_open_stage(
                message: "CellSpace Geometry 추출 완료: #{cell_snapshots_by_source.length}개"
              )
              tracker.start_stage(
                'State/Transition 구성',
                total: result.length,
                message: "State/Transition 구성: 0 / #{result.length}"
              )
              @gml_export_transition_stage_started = true
            end
            result
          end

          def build_transition_snapshot(transition, cell_snapshots_by_source)
            result = super
            tracker = GmlExportProgressContext.current
            tracker&.advance(message: 'State 연결과 Transition endpoint 구성 중') if tracker&.active?
            result
          end
        end

        module GmlWriterProgressIntegration
          def to_xml
            tracker = GmlExportProgressContext.current
            return super unless tracker&.active?

            total = (@snapshot.cell_spaces.length * 2) + @snapshot.transitions.length
            tracker.start_stage(
              'GML 구조 생성',
              total: total,
              message: "GML 구조 생성: 0 / #{total}"
            )
            super
          end

          private

          def append_cell_space(parent, cell_space)
            result = super
            tracker = GmlExportProgressContext.current
            tracker&.advance(message: 'CellSpace Solid/Surface GML 생성 중') if tracker&.active?
            result
          end

          def transitions_for_state(state)
            result = super
            tracker = GmlExportProgressContext.current
            tracker&.advance(message: 'State GML 생성 중') if tracker&.active?
            result
          end

          def append_transitions(space_layer)
            result = super
            tracker = GmlExportProgressContext.current
            if tracker&.active?
              tracker.advance(
                by: @snapshot.transitions.length,
                message: 'Transition GML 생성 완료'
              )
            end
            result
          end

          def pretty_xml(doc)
            tracker = GmlExportProgressContext.current
            return super unless tracker&.active?

            tracker.finish_open_stage(message: 'GML 구조 생성 완료')
            tracker.start_stage(
              'XML 변환 및 파일 저장',
              total: 2,
              message: 'REXML 문서를 XML 문자열로 변환 중'
            )
            result = super
            tracker.advance(message: 'XML 문자열 생성 완료')
            result
          end
        end
      end

      if defined?(CommandDispatcher)
        CommandDispatcher.prepend(
          ProductionProgress::ExportCommandsProgressIntegration
        ) unless CommandDispatcher.ancestors.include?(
          ProductionProgress::ExportCommandsProgressIntegration
        )
      end

      if defined?(IndoorGmlConverter::GmlExporter)
        IndoorGmlConverter::GmlExporter.prepend(
          ProductionProgress::GmlExporterProgressIntegration
        ) unless IndoorGmlConverter::GmlExporter.ancestors.include?(
          ProductionProgress::GmlExporterProgressIntegration
        )
      end

      if defined?(IndoorGmlConverter::ExportSnapshot::Builder)
        IndoorGmlConverter::ExportSnapshot::Builder.prepend(
          ProductionProgress::ExportSnapshotBuilderProgressIntegration
        ) unless IndoorGmlConverter::ExportSnapshot::Builder.ancestors.include?(
          ProductionProgress::ExportSnapshotBuilderProgressIntegration
        )
      end

      if defined?(IndoorGmlConverter::GmlWriter)
        IndoorGmlConverter::GmlWriter.prepend(
          ProductionProgress::GmlWriterProgressIntegration
        ) unless IndoorGmlConverter::GmlWriter.ancestors.include?(
          ProductionProgress::GmlWriterProgressIntegration
        )
      end
    end
  end
end
