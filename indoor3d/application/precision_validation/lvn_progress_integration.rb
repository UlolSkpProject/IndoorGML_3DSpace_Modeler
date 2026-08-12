# frozen_string_literal: true

require_relative '../progress/adaptive_progress_checkpoint'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        module LvnProgressContext
          THREAD_KEY = :ulol_indoor_gml_precision_lvn_progress

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

        class ValidationLvnProgressAdapter
          def initialize(progress, step: :lvn, logger: IndoorCore::Logger)
            @progress = progress
            @step = step
            @logger = logger
          end

          def active?
            @progress&.respond_to?(:detail) == true
          end

          def detail(percent:, phase:, message:, current: nil)
            return false unless active?

            @progress.detail(
              @step,
              percent: percent,
              phase: phase,
              message: message,
              current: current
            )
            true
          rescue StandardError => error
            log_error('detail', error)
            false
          end

          private

          def log_error(context, error)
            @logger.puts(
              "[IndoorGML] LVN validation progress #{context} failed: " \
              "#{error.class}: #{error.message}"
            )
          rescue StandardError
            nil
          end
        end

        class LvnProgressTracker
          PLAN_PERCENT = 5
          CELL_END_PERCENT = 98
          FINISH_PERCENT = 99
          NORMALIZER_STAGE_PROGRESS = {
            source_entity_validation: [7, 'Validating CellSpace geometry'],
            unique_definition_check: [10, 'Preparing an independent geometry definition'],
            vertex_target_metrics: [14, 'Calculating normalized vertex targets'],
            short_edge_sliver_plan: [17, 'Inspecting short-edge slivers'],
            source_brep_snapshot: [22, 'Extracting the source boundary mesh'],
            conforming_source: [30, 'Conforming source boundary segments'],
            source_altitude_sliver_collapse: [34, 'Repairing source sliver triangles'],
            grid_target_projection: [39, 'Projecting vertices to the local grid'],
            triangle_shape_validation: [44, 'Validating normalized triangles'],
            conforming_grid: [49, 'Conforming normalized boundary segments'],
            triangle_mesh_inventory: [52, 'Building normalized mesh inventory'],
            short_edge_sliver_collapse: [55, 'Collapsing repairable short-edge slivers'],
            closed_mesh_and_intersection_validation: [66, 'Validating the closed normalized mesh'],
            triangle_intersection_validation: [70, 'Checking triangle intersections'],
            erase_source_geometry: [73, 'Replacing the source geometry'],
            sketchup_face_rebuild: [80, 'Rebuilding SketchUp faces'],
            rebuilt_geometry_snapshot: [84, 'Inspecting rebuilt geometry'],
            triangle_rebuild_validation: [87, 'Validating rebuilt triangles'],
            orient_and_coplanar_cleanup: [91, 'Orienting faces and cleaning coplanar edges'],
            coplanar_shared_edge_cleanup: [93, 'Cleaning coplanar shared edges'],
            final_entity_repair: [94, 'Applying final solid repairs'],
            rebuilt_entity_validation: [95, 'Validating the rebuilt solid'],
            final_grid_residual: [96, 'Checking final grid residuals'],
            surface_equivalence: [97, 'Verifying surface equivalence']
          }.freeze

          def initialize(adapter, logger: IndoorCore::Logger)
            @adapter = adapter
            @logger = logger
            reset
          end

          def active?
            @adapter&.active? == true
          end

          def start(total:)
            reset
            @total_targets = [total.to_i, 0].max
            emit(
              percent: 1,
              message: "Preparing CellSpace Normalize: #{@total_targets} targets"
            )
          end

          def plan_ready(rows:, execution_targets:)
            skipped = Array(rows).length
            execution = Array(execution_targets).length
            emit(
              percent: PLAN_PERCENT,
              message: "LVN plan: normalize #{execution}, skip #{skipped}"
            )
          end

          def begin_cells(total:)
            @phase = :cells
            @phase_total = [total.to_i, 0].max
            @phase_completed = 0
            @phase_start_percent = [@last_percent, PLAN_PERCENT].max
            @phase_end_percent = [CELL_END_PERCENT, @phase_start_percent].max
            @checkpoint = ProductionProgress::AdaptiveProgressCheckpoint.new(@phase_total)
            emit(
              percent: @phase_start_percent,
              message: 'Normalizing CellSpaces with independent Undo operations'
            )
          end

          def cells_completed
            return false unless @phase == :cells

            emit(
              percent: [@last_percent, CELL_END_PERCENT].max,
              message: 'CellSpace Normalize attempts completed'
            )
          end

          def cell_started(cell_space)
            return false unless active_phase?

            @current_cell_space_id = cell_space_id(cell_space)
            return false unless @phase_completed.zero?

            emit(
              percent: @last_percent,
              message: phase_message(1),
              current: @current_cell_space_id
            )
          end

          def cell_finished(cell_space, status: :normalized)
            return false unless active_phase?

            @phase_completed = [@phase_completed + 1, @phase_total].min
            return true unless @checkpoint&.checkpoint?(@phase_completed)

            emit(
              percent: phase_percent,
              message: phase_message(@phase_completed, status: status),
              current: cell_space_id(cell_space)
            )
          end

          def normalizer_stage_started(stage, details: nil)
            progress = NORMALIZER_STAGE_PROGRESS[stage.to_sym]
            return false unless progress

            percent, message = progress
            triangle_count = details[:triangle_count] if details.respond_to?(:[])
            message = "#{message} (#{triangle_count} triangles)" if triangle_count.to_i.positive?
            emit(
              percent: normalizer_stage_percent(percent),
              phase: 'Vertex Normalize',
              message: message,
              current: @current_cell_space_id
            )
          rescue StandardError => error
            log_error('normalizer stage', error)
            false
          end

          def finish(report = nil)
            data = report.respond_to?(:to_h) ? report.to_h : {}
            normalized = data[:cell_space_count].to_i
            failed = data[:normalization_failed_cell_space_count].to_i
            skipped = data[:skipped_previous_failure_cell_space_count].to_i +
                      data[:already_normalized_cell_space_count].to_i
            emit(
              percent: FINISH_PERCENT,
              message: "LVN processed: normalized #{normalized}, failed #{failed}, skipped #{skipped}"
            )
          end

          def fail(error)
            emit(
              percent: @last_percent,
              message: "CellSpace Normalize failed: #{error.message}"
            )
          end

          private

          def reset
            @total_targets = 0
            @phase = nil
            @phase_total = 0
            @phase_completed = 0
            @phase_start_percent = 0
            @phase_end_percent = 0
            @checkpoint = nil
            @last_percent = 0
            @current_cell_space_id = nil
          end

          def active_phase?
            active? && @phase == :cells && @phase_total.positive?
          end

          def phase_percent
            ratio = @phase_completed.fdiv(@phase_total)
            value = @phase_start_percent +
                    ((@phase_end_percent - @phase_start_percent) * ratio)
            value.round
          end

          def normalizer_stage_percent(stage_percent)
            return stage_percent unless active_phase?

            stage_span = CELL_END_PERCENT - PLAN_PERCENT
            ratio = (stage_percent.to_f - PLAN_PERCENT).fdiv(stage_span)
            ratio = [[ratio, 0.0].max, 1.0].min
            cell_ratio = (@phase_completed + ratio).fdiv(@phase_total)
            value = @phase_start_percent +
                    ((@phase_end_percent - @phase_start_percent) * cell_ratio)
            value.round
          end

          def phase_message(completed, status: nil)
            suffix = status == :failed ? ' (failed; rollback completed)' : ''
            "CellSpace Normalize: #{completed} / #{@phase_total}#{suffix}"
          end

          def cell_space_id(cell_space)
            return cell_space.id.to_s if cell_space&.respond_to?(:id)

            cell_space.to_s
          rescue StandardError
            nil
          end

          def emit(percent:, message:, phase: 'CellSpace Normalize', current: nil)
            return false unless active?

            bounded = [[percent.to_i, @last_percent].max, 100].min
            @last_percent = bounded
            @adapter.detail(
              percent: bounded,
              phase: phase,
              message: message.to_s,
              current: current
            )
          rescue StandardError => error
            log_error('emit', error)
            false
          end

          def log_error(context, error)
            @logger.puts(
              "[IndoorGML] LVN progress tracker #{context} failed: " \
              "#{error.class}: #{error.message}"
            )
          rescue StandardError
            nil
          end
        end

        module LvnProgressCommandDispatcherPatch
          private

          def perform_check_validity(session)
            return super unless lvn_progress_precision_session?(session)
            return super if LvnProgressContext.current

            adapter = ValidationLvnProgressAdapter.new(session.progress)
            tracker = LvnProgressTracker.new(adapter)
            LvnProgressContext.with(tracker) { super }
          end

          def lvn_progress_precision_session?(session)
            return false unless respond_to?(:precision_validation_session?, true)

            send(:precision_validation_session?, session)
          rescue StandardError
            false
          end
        end

        module LvnProgressIndoorModelPatch
          def local_vertex_normalize(*arguments, **options)
            tracker = LvnProgressContext.current
            return super unless tracker&.active?

            tracker.start(total: lvn_progress_target_count(options[:cell_spaces]))
            result = super
            tracker.finish(result)
            result
          rescue StandardError => error
            tracker&.fail(error)
            raise
          end

          private

          def build_continue_execution_plan(*arguments, **options)
            plan = super
            tracker = LvnProgressContext.current
            tracker&.plan_ready(
              rows: plan[:rows],
              execution_targets: plan[:execution_targets]
            )
            plan
          end

          def local_vertex_normalize_continue_per_cell(*arguments, **options)
            execution_targets = arguments[3] || options[:execution_targets]
            tracker = LvnProgressContext.current
            tracker&.begin_cells(total: Array(execution_targets).length)
            super
          end

          def normalize_cell_space_continue(cell_space, *arguments, **options)
            tracker = LvnProgressContext.current
            tracker&.cell_started(cell_space)
            row = super
            tracker&.cell_finished(cell_space, status: row[:status])
            row
          rescue StandardError
            tracker&.cell_finished(cell_space, status: :failed)
            raise
          end

          def lvn_progress_target_count(cell_spaces)
            Array(normalization_targets(cell_spaces)).length
          rescue StandardError
            source = cell_spaces.nil? ? instance_variable_get(:@cell_spaces) : cell_spaces
            Array(source).length
          end
        end

        def self.install_lvn_progress!
          if defined?(CommandDispatcher) &&
             !CommandDispatcher.ancestors.include?(LvnProgressCommandDispatcherPatch)
            CommandDispatcher.prepend(LvnProgressCommandDispatcherPatch)
          end

          if defined?(IndoorModel) &&
             !IndoorModel.ancestors.include?(LvnProgressIndoorModelPatch)
            IndoorModel.prepend(LvnProgressIndoorModelPatch)
          end

          true
        end
      end

      PrecisionValidation.install_lvn_progress!
    end
  end
end
