# frozen_string_literal: true

require_relative 'scoped_method_override'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionRollbackFailureRunner
        MAX_JOBS = 5 unless const_defined?(:MAX_JOBS, false)
        VERIFY_DELAY = 0.1 unless const_defined?(:VERIFY_DELAY, false)
        OPERATION_NAME = '[DEV] Injected CellSpace Rollback'.freeze unless const_defined?(:OPERATION_NAME, false)

        class InjectedRollbackFailure < StandardError; end unless const_defined?(:InjectedRollbackFailure, false)

        class TransactionProbe < Sketchup::ModelObserver
          attr_reader :events

          def initialize
            super()
            @events = []
          end

          def onTransactionStart(_model)
            @events << :start
          end

          def onTransactionCommit(_model)
            @events << :commit
          end

          def onTransactionEmpty(_model)
            @events << :empty
          end

          def onTransactionAbort(_model)
            @events << :abort
          end

          def onTransactionUndo(_model)
            @events << :undo
          end

          def onTransactionRedo(_model)
            @events << :redo
          end
        end unless const_defined?(:TransactionProbe, false)

        class << self
          def run!(
            fallback_cell_type: CellSpaceType::GENERAL,
            fallback_category_code: nil,
            max_jobs: MAX_JOBS
          )
            return false if @running

            @running = true
            @last_result = nil
            @scheduled_timer_id = UI.start_timer(0, false) do
              @scheduled_timer_id = nil
              execute!(
                fallback_cell_type: fallback_cell_type,
                fallback_category_code: fallback_category_code,
                max_jobs: max_jobs
              )
              false
            end
            puts '[CELLSPACE ROLLBACK FAILURE] scheduled after current UI callback'
            true
          rescue StandardError => e
            @running = false
            @last_result = failure_payload(:schedule_failed, e)
            puts "[CELLSPACE ROLLBACK FAILURE] schedule failed: #{e.class}: #{e.message}"
            false
          end

          def status!
            payload = (@last_result || { type: @running ? :running : :idle }).dup.freeze
            puts "[CELLSPACE ROLLBACK FAILURE STATUS] #{payload.inspect}"
            payload
          end

          def running?
            @running == true
          end

          private

          def execute!(fallback_cell_type:, fallback_category_code:, max_jobs:)
            model = Sketchup.active_model
            indoor_model = IndoorModel.current
            raise 'No active SketchUp model' unless model
            raise 'Rollback failure test is unavailable in Edit Mode' if indoor_model.editing?
            raise 'Rollback failure test is unavailable during validation focus' if indoor_model.validation_focus_active?

            selection = model.selection.to_a
            initial_active_path = active_path_snapshot(model)
            before = capture_model_state(model, indoor_model)

            prepared = indoor_model.prepare_cell_space_creation_active_context(model)
            raise 'Failed to prepare CellSpace conversion context' unless prepared == true

            conversion_active_path = active_path_snapshot(model)
            jobs = CellSpaceConversionJobBuilder.new(entities: selection).build
            validate_job_count!(jobs, max_jobs)
            source_snapshots = jobs.map { |job| source_snapshot(job.fetch(:source)) }.freeze
            fallback_target = [fallback_cell_type, fallback_category_code].freeze
            probe = TransactionProbe.new
            model.add_observer(probe)
            injection_hits = 0
            expected_failure = false
            unexpected_error = nil
            service_result = nil

            override = ThreadedProgressInfrastructure::ScopedMethodOverride.new(
              target: indoor_model,
              method_name: :synchronize_topology_after_bulk_conversion,
              visibility: :private
            ) do
              injection_hits += 1
              raise InjectedRollbackFailure,
                    'Injected failure before topology synchronization to verify full operation rollback'
            end

            begin
              override.call do
                service_result = indoor_model.convert_cell_space_jobs_bulk(
                  jobs,
                  fallback_target: fallback_target,
                  original_active_path: conversion_active_path,
                  operation_name: OPERATION_NAME,
                  activate_root_context: true
                )
              end
            rescue InjectedRollbackFailure => e
              expected_failure = true
              puts "[CELLSPACE ROLLBACK FAILURE] expected failure caught: #{e.message}"
            rescue StandardError => e
              unexpected_error = e
              puts "[CELLSPACE ROLLBACK FAILURE] unexpected failure: #{e.class}: #{e.message}"
            ensure
              restore_active_path(indoor_model, model, initial_active_path)
            end

            context = {
              model: model,
              indoor_model: indoor_model,
              probe: probe,
              jobs: jobs,
              source_snapshots: source_snapshots,
              before: before,
              initial_active_path: initial_active_path,
              expected_failure: expected_failure,
              unexpected_error: unexpected_error,
              injection_hits: injection_hits,
              service_result: service_result
            }
            UI.start_timer(VERIFY_DELAY, false) do
              finalize!(context)
              false
            end
            true
          rescue StandardError => e
            @running = false
            @last_result = failure_payload(:setup_failed, e)
            puts "[CELLSPACE ROLLBACK FAILURE] setup failed: #{e.class}: #{e.message}"
            false
          end

          def finalize!(context)
            model = context.fetch(:model)
            indoor_model = context.fetch(:indoor_model)
            probe = context.fetch(:probe)
            model.remove_observer(probe)
            restore_active_path(indoor_model, model, context[:initial_active_path])

            after = capture_model_state(model, indoor_model)
            sources_after = context.fetch(:source_snapshots).map do |snapshot|
              entity = find_entity(model, snapshot[:persistent_id])
              entity ? source_snapshot(entity) : nil
            end
            source_snapshot_unchanged = sources_after == context.fetch(:source_snapshots)
            root_entities_unchanged = after[:root_entity_ids] == context.dig(:before, :root_entity_ids)
            feature_counts_unchanged = after[:feature_counts] == context.dig(:before, :feature_counts)
            active_path_restored = after[:active_path] == context.dig(:before, :active_path)
            replay_idle = indoor_model.transaction_replay_pending? != true
            abort_count = probe.events.count(:abort)
            commit_count = probe.events.count(:commit)
            empty_count = probe.events.count(:empty)
            undo_count = probe.events.count(:undo)
            redo_count = probe.events.count(:redo)
            transaction_abort_clean =
              abort_count.positive? &&
              commit_count.zero? &&
              empty_count.zero? &&
              undo_count.zero? &&
              redo_count.zero?

            unexpected_error = context[:unexpected_error]
            passed =
              context[:expected_failure] == true &&
              unexpected_error.nil? &&
              context[:injection_hits] == 1 &&
              context[:service_result].nil? &&
              root_entities_unchanged &&
              feature_counts_unchanged &&
              source_snapshot_unchanged &&
              active_path_restored &&
              replay_idle &&
              transaction_abort_clean

            @last_result = {
              type: passed ? :completed : :failed,
              passed: passed,
              injected_failure_caught: context[:expected_failure] == true,
              injection_hits: context[:injection_hits],
              unexpected_error_class: unexpected_error&.class&.name,
              unexpected_error_message: unexpected_error&.message,
              service_returned: !context[:service_result].nil?,
              job_count: context.fetch(:jobs).length,
              feature_counts_before: context.dig(:before, :feature_counts),
              feature_counts_after: after[:feature_counts],
              feature_counts_unchanged: feature_counts_unchanged,
              root_entity_count_before: context.dig(:before, :root_entity_ids).length,
              root_entity_count_after: after[:root_entity_ids].length,
              root_entities_unchanged: root_entities_unchanged,
              source_snapshot_unchanged: source_snapshot_unchanged,
              sources_still_valid: sources_after.none?(&:nil?),
              active_path_restored: active_path_restored,
              transaction_replay_pending: indoor_model.transaction_replay_pending? == true,
              observer_events: probe.events.dup.freeze,
              transaction_abort_count: abort_count,
              transaction_commit_count: commit_count,
              transaction_empty_count: empty_count,
              transaction_undo_count: undo_count,
              transaction_redo_count: redo_count,
              transaction_abort_clean: transaction_abort_clean
            }.freeze
            puts "[CELLSPACE ROLLBACK FAILURE RESULT] #{@last_result.inspect}"
            @last_result
          rescue StandardError => e
            @last_result = failure_payload(:verification_failed, e)
            puts "[CELLSPACE ROLLBACK FAILURE] verification failed: #{e.class}: #{e.message}"
            @last_result
          ensure
            @running = false
          end

          def validate_job_count!(jobs, max_jobs)
            count = Array(jobs).length
            raise 'Select at least one unconverted solid Group or ComponentInstance' if count.zero?

            limit = max_jobs.to_i
            raise ArgumentError, 'max_jobs must be positive' unless limit.positive?
            raise "Rollback test blocked: #{count} jobs exceed safety limit #{limit}" if count > limit
          end

          def capture_model_state(model, indoor_model)
            {
              root_entity_ids: root_entity_ids(model),
              feature_counts: feature_counts(indoor_model),
              active_path: active_path_snapshot(model)
            }.freeze
          end

          def feature_counts(indoor_model)
            {
              cell_spaces: valid_feature_count(indoor_model.cell_spaces),
              states: valid_feature_count(indoor_model.states),
              transitions: valid_feature_count(indoor_model.transitions)
            }.freeze
          end

          def valid_feature_count(collection)
            Array(collection).count { |feature| feature&.valid? }
          rescue StandardError
            0
          end

          def root_entity_ids(model)
            model.entities.to_a.filter_map do |entity|
              entity.persistent_id if entity&.valid? && entity.respond_to?(:persistent_id)
            end.sort.freeze
          end

          def source_snapshot(entity)
            raise 'Source entity is unavailable' unless entity&.valid?

            {
              persistent_id: entity.persistent_id,
              class_name: entity.class.name.to_s,
              name: entity.respond_to?(:name) ? entity.name.to_s : '',
              transformation: transformation_signature(entity),
              layer_name: entity.respond_to?(:layer) ? entity.layer&.name.to_s : '',
              material_name: entity.respond_to?(:material) ? entity.material&.name.to_s : '',
              visible: entity.respond_to?(:visible?) ? entity.visible? : nil,
              definition_guid: definition_guid(entity),
              definition_entity_count: definition_entity_count(entity),
              bounds: bounds_signature(entity)
            }.freeze
          end

          def transformation_signature(entity)
            transformation = entity.respond_to?(:transformation) ? entity.transformation : nil
            transformation&.to_a&.map { |value| value.to_f.round(6) }
          rescue StandardError
            nil
          end

          def definition_guid(entity)
            definition = entity.respond_to?(:definition) ? entity.definition : nil
            definition&.guid.to_s
          rescue StandardError
            ''
          end

          def definition_entity_count(entity)
            definition = entity.respond_to?(:definition) ? entity.definition : nil
            definition&.entities&.length.to_i
          rescue StandardError
            0
          end

          def bounds_signature(entity)
            bounds = entity.respond_to?(:bounds) ? entity.bounds : nil
            return nil unless bounds

            [bounds.min, bounds.max].flat_map do |point|
              [point.x.to_f.round(6), point.y.to_f.round(6), point.z.to_f.round(6)]
            end.freeze
          rescue StandardError
            nil
          end

          def find_entity(model, persistent_id)
            model.find_entity_by_persistent_id(persistent_id)
          rescue StandardError
            nil
          end

          def active_path_snapshot(model)
            path = model.active_path
            return nil if path.nil?

            path.filter_map do |entity|
              entity.persistent_id if entity&.valid? && entity.respond_to?(:persistent_id)
            end.freeze
          rescue StandardError
            nil
          end

          def restore_active_path(indoor_model, model, snapshot)
            controller = ActivePathController.new(model, logger: IndoorCore::Logger)
            indoor_model.with_active_path_enforcement_suspended do
              controller.restore(snapshot, close_when_nil: true)
            end
            true
          rescue StandardError => e
            puts "[CELLSPACE ROLLBACK FAILURE] active path restore failed: #{e.class}: #{e.message}"
            false
          end

          def failure_payload(type, error)
            {
              type: type,
              passed: false,
              error_class: error.class.name,
              error_message: error.message
            }.freeze
          end
        end
      end
    end
  end
end

puts '[CELLSPACE CONVERSION ROLLBACK FAILURE RUNNER] loaded'
