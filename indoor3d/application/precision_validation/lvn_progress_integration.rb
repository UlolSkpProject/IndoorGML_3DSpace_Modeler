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
          ATOMIC_END_PERCENT = 80
          FALLBACK_END_PERCENT = 90
          TOPOLOGY_START_PERCENT = 92
          TOPOLOGY_END_PERCENT = 98
          FINISH_PERCENT = 99

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

          def plan_ready(rows:, atomic_targets:, fallback_targets:)
            skipped = Array(rows).length
            atomic = Array(atomic_targets).length
            fallback = Array(fallback_targets).length
            emit(
              percent: PLAN_PERCENT,
              message: "LVN plan: normalize #{atomic + fallback}, skip #{skipped}"
            )
          end

          def begin_atomic(total:)
            begin_phase(
              :atomic,
              total: total,
              start_percent: [@last_percent, PLAN_PERCENT].max,
              end_percent: ATOMIC_END_PERCENT,
              message: 'Normalizing CellSpaces in one Undo operation'
            )
          end

          def atomic_completed(report = nil)
            return false unless @phase == :atomic
            return false if report.respond_to?(:[]) && report[:atomic_fallback] == true

            emit(
              percent: [@last_percent, FALLBACK_END_PERCENT].max,
              message: 'CellSpace Normalize operation completed'
            )
          end

          def begin_fallback(total:, atomic_attempted: false)
            message = if atomic_attempted
                        'Atomic Normalize failed; retrying CellSpaces individually'
                      else
                        'Normalizing CellSpaces individually'
                      end
            begin_phase(
              :fallback,
              total: total,
              start_percent: [@last_percent, PLAN_PERCENT].max,
              end_percent: FALLBACK_END_PERCENT,
              message: message
            )
          end

          def fallback_completed
            return false unless @phase == :fallback

            emit(
              percent: [@last_percent, FALLBACK_END_PERCENT].max,
              message: 'CellSpace Normalize attempts completed'
            )
          end

          def cell_started(cell_space)
            return false unless active_phase?
            return false unless @phase_completed.zero?

            emit(
              percent: @last_percent,
              message: phase_message(1),
              current: cell_space_id(cell_space)
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

          def topology_started
            @topology_running = true
            emit(
              percent: [@last_percent, TOPOLOGY_START_PERCENT].max,
              phase: 'Topology Synchronize',
              message: 'Synchronizing Adjacency and Transitions'
            )
          end

          def topology_finished
            return false unless @topology_running

            @topology_running = false
            emit(
              percent: [@last_percent, TOPOLOGY_END_PERCENT].max,
              phase: 'Topology Synchronize',
              message: 'Adjacency and Transition synchronization completed'
            )
          end

          def topology_failed(error)
            return false unless @topology_running

            @topology_running = false
            emit(
              percent: @last_percent,
              phase: 'Topology Synchronize',
              message: "Topology synchronization failed; LVN recovery will continue (#{error.class})"
            )
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
            @topology_running = false
            @last_percent = 0
          end

          def begin_phase(name, total:, start_percent:, end_percent:, message:)
            @phase = name
            @phase_total = [total.to_i, 0].max
            @phase_completed = 0
            @phase_start_percent = [start_percent.to_i, @last_percent].max
            @phase_end_percent = [end_percent.to_i, @phase_start_percent].max
            @checkpoint = ProductionProgress::AdaptiveProgressCheckpoint.new(@phase_total)
            emit(percent: @phase_start_percent, message: message)
          end

          def active_phase?
            active? && %i[atomic fallback].include?(@phase) && @phase_total.positive?
          end

          def phase_percent
            ratio = @phase_completed.fdiv(@phase_total)
            value = @phase_start_percent +
                    ((@phase_end_percent - @phase_start_percent) * ratio)
            value.round
          end

          def phase_message(completed, status: nil)
            prefix = @phase == :atomic ? 'Atomic CellSpace Normalize' : 'CellSpace Normalize retry'
            suffix = status == :failed ? ' (failed; rollback/recovery)' : ''
            "#{prefix}: #{completed} / #{@phase_total}#{suffix}"
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
              atomic_targets: plan[:atomic_targets],
              fallback_targets: plan[:fallback_targets]
            )
            plan
          end

          def local_vertex_normalize_continue_atomic(*arguments, **options)
            plan = arguments[2] || options[:plan] || {}
            tracker = LvnProgressContext.current
            tracker&.begin_atomic(total: Array(plan[:atomic_targets]).length)
            report = super
            tracker&.atomic_completed(report)
            report
          end

          def local_vertex_normalize_continue_per_cell(*arguments, **options)
            execution_targets = arguments[3] || options[:execution_targets]
            atomic_attempted = options[:atomic_attempted] == true
            tracker = LvnProgressContext.current
            tracker&.begin_fallback(
              total: Array(execution_targets).length,
              atomic_attempted: atomic_attempted
            )
            report = super
            tracker&.fallback_completed
            report
          end

          def normalize_cell_space_group(cell_space, *arguments, **options)
            tracker = LvnProgressContext.current
            tracker&.cell_started(cell_space)
            result = super
            tracker&.cell_finished(cell_space, status: :normalized)
            result
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

        module LvnProgressTopologyCoordinatorPatch
          def synchronize_all(*arguments, **options)
            tracker = LvnProgressContext.current
            return super unless tracker&.active?

            tracker.topology_started
            result = super
            tracker.topology_finished
            result
          rescue StandardError => error
            tracker&.topology_failed(error)
            raise
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

          if defined?(TopologyCoordinator) &&
             !TopologyCoordinator.ancestors.include?(LvnProgressTopologyCoordinatorPatch)
            TopologyCoordinator.prepend(LvnProgressTopologyCoordinatorPatch)
          end

          true
        end
      end

      PrecisionValidation.install_lvn_progress!
    end
  end
end
