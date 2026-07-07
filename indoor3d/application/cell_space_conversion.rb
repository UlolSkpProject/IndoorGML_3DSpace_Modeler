# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionJobBuilder
        def initialize(entities:, parent_target: active_context_parent_target, ancestors: active_context_ancestors)
          @entities = Array(entities)
          @parent_target = parent_target
          @ancestors = Array(ancestors)
        end

        def build
          @entities.each_with_object([]) do |entity, jobs|
            next unless convertible_container?(entity)

            collect(
              entity,
              Utils::Transformation.entity_transformation_in_active_context(entity),
              @parent_target,
              @ancestors,
              jobs
            )
          end
        end

        private

        def active_context_parent_target
          parent = Sketchup.active_model&.active_path&.last
          parent ? IndoorCore.tag_cell_space_type_and_category(parent) : nil
        rescue StandardError
          nil
        end

        def active_context_ancestors
          (Sketchup.active_model&.active_path || []).select { |entity| cleanup_candidate_container?(entity) }
        rescue StandardError
          []
        end

        def collect(entity, world_transformation, parent_target, ancestors, jobs)
          return unless entity&.valid?
          return unless convertible_container?(entity)
          return if indoor_feature(entity) == 'CellSpace'

          if solid_container?(entity)
            jobs << {
              source: entity,
              transformation: world_transformation,
              ancestors: ancestors.dup,
              target: target_for_entity(entity, parent_target)
            }
            return
          end

          entity_target = IndoorCore.tag_cell_space_type_and_category(entity)
          return unless entity.respond_to?(:definition) && entity.definition&.valid?

          child_ancestors = cleanup_candidate_container?(entity) ? ancestors + [entity] : ancestors
          entity.definition.entities.to_a.each do |child|
            next unless child&.valid?
            next unless convertible_container?(child)

            collect(
              child,
              world_transformation * child.transformation,
              entity_target,
              child_ancestors,
              jobs
            )
          end
        end

        def target_for_entity(entity, parent_target)
          entity_target = IndoorCore.tag_cell_space_type_and_category(entity)
          return entity_target if entity_target
          return parent_target unless IndoorCore.tag_assigned?(entity)

          nil
        end

        def cleanup_candidate_container?(entity)
          entity&.valid? &&
            convertible_container?(entity) &&
            indoor_feature(entity).to_s.empty?
        rescue StandardError
          false
        end

        def convertible_container?(entity)
          entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        end

        def solid_container?(entity)
          entity.respond_to?(:manifold?) && entity.manifold?
        rescue StandardError
          false
        end

        def indoor_feature(entity)
          entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
        rescue StandardError
          nil
        end
      end

      class CellSpaceConversionExecutor
        Result = Struct.new(:converted, :errors, keyword_init: true) do
          def converted?
            converted == true
          end
        end

        COPY_ATTRIBUTES = [:name, :material, :layer, :visible].freeze

        def initialize(target_entities:, converter:, preserve_source: nil, logger: Logger, labeler: nil)
          @target_entities = target_entities
          @converter = converter
          @preserve_source = preserve_source
          @logger = logger
          @labeler = labeler || method(:default_label)
        end

        def execute(job, fallback_target:)
          execute!(job, fallback_target: fallback_target)
        rescue StandardError => e
          @logger.puts "[IndoorGML] CellSpace conversion failed: #{e.class}: #{e.message}"
          cleanup_failed_source(@prepared_source) if @cleanup_source_on_failure
          Result.new(
            converted: false,
            errors: [{ group: @labeler.call(job[:source]), reason: e.message }]
          )
        ensure
          @prepared_source = nil
          @cleanup_source_on_failure = false
        end

        def execute!(job, fallback_target:)
          target_cell_type, target_category_code = job[:target] || fallback_target
          source, erase_original_after_success, cleanup_source_on_failure = prepare_source(job)
          @prepared_source = source
          @cleanup_source_on_failure = cleanup_source_on_failure
          @converter.call(source, target_cell_type, target_category_code)
          job[:source].erase! if erase_original_after_success && job[:source]&.valid?
          cleanup_empty_ancestors(job)
          Result.new(converted: true, errors: [])
        end

        private

        def prepare_source(job)
          source = job[:source]
          return [source, false, false] if @preserve_source&.call(source)

          [
            EntityCopyHelper.copy_instance(
              source: source,
              target_entities: @target_entities,
              transformation: job[:transformation],
              convert_to_group: :source_group,
              make_unique: :source_group,
              copy_attributes: COPY_ATTRIBUTES
            ),
            true,
            true
          ]
        end

        def cleanup_failed_source(source)
          source.erase! if source&.valid? && indoor_feature(source) != 'CellSpace'
        end

        def cleanup_empty_ancestors(job)
          Array(job[:ancestors]).reverse_each do |entity|
            cleanup_empty_container(entity)
          end
        end

        def cleanup_empty_container(entity)
          return false unless cleanup_candidate_container?(entity)
          return false unless entity.respond_to?(:definition) && entity.definition&.valid?
          return false unless entity.definition.entities.to_a.empty?

          entity.erase!
          true
        rescue StandardError => e
          @logger.puts "[IndoorGML] Empty source group cleanup failed: #{e.class}: #{e.message}"
          false
        end

        def cleanup_candidate_container?(entity)
          entity&.valid? &&
            (entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)) &&
            indoor_feature(entity).to_s.empty?
        rescue StandardError
          false
        end

        def indoor_feature(entity)
          entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
        rescue StandardError
          nil
        end

        def default_label(entity)
          entity.respond_to?(:name) ? entity.name.to_s : entity.to_s
        end
      end

      class BulkCellSpaceConversionService
        Result = Struct.new(:converted_count, :errors, :metrics, keyword_init: true)

        def initialize(model:, jobs:, fallback_target:, target_entities:, converter:, synchronize_all:, apply_lock_policy:, runtime_snapshot:, runtime_restore:, apply_guards:, restore_active_path:, activate_root_context:, clear_dirty_topology:, logger: Logger, labeler: nil, preserve_source: nil, operation_name: 'Convert Solid Groups to CellSpace')
          @model = model
          @jobs = Array(jobs)
          @fallback_target = fallback_target
          @target_entities = target_entities
          @converter = converter
          @synchronize_all = synchronize_all
          @apply_lock_policy = apply_lock_policy
          @runtime_snapshot = runtime_snapshot
          @runtime_restore = runtime_restore
          @apply_guards = apply_guards
          @restore_active_path = restore_active_path
          @activate_root_context = activate_root_context
          @clear_dirty_topology = clear_dirty_topology
          @logger = logger
          @labeler = labeler || proc { |entity| entity.respond_to?(:name) ? entity.name.to_s : entity.to_s }
          @preserve_source = preserve_source
          @operation_name = operation_name
        end

        def call
          started_at = monotonic_time
          metrics = {}
          errors = []
          plan, preparation_errors = timed(metrics, :job_preparation) { prepare_plan }
          errors.concat(preparation_errors)
          plan, geometry_errors = timed(metrics, :geometry_validation) { validate_plan_geometry(plan) }
          errors.concat(geometry_errors)
          plan, target_errors = timed(metrics, :adjacency_candidate_generation) { validate_plan_targets(plan) }
          errors.concat(target_errors)
          converted_count = 0
          apply_metrics = {}
          unless plan.empty?
            converted_count, apply_errors, apply_metrics = timed(metrics, :cell_space_entity_apply) { apply_plan(plan) }
            errors.concat(apply_errors)
          end
          metrics.merge!(apply_metrics)
          metrics[:total_duration] = elapsed_since(started_at)
          Result.new(converted_count: converted_count, errors: errors, metrics: metrics)
        end

        private

        def prepare_plan
          errors = []
          plan = @jobs.each_with_index.filter_map do |job, index|
            source = job[:source]
            unless source&.respond_to?(:valid?) && source.valid?
              errors << conversion_error(source, 'Conversion source is no longer valid')
              next
            end

            job.merge(job_id: "cell_space_conversion_#{index}")
          end.freeze
          errors << conversion_error(nil, 'No valid solid groups were available for conversion') if plan.empty? && errors.empty?
          [plan, errors]
        end

        def validate_plan_geometry(plan)
          return [plan, []] unless defined?(Utils::Geometry) && Utils::Geometry.respond_to?(:validate_cell_space_source_group)

          errors = []
          valid_plan = plan.filter_map do |job|
            entities = job[:source]&.definition&.entities if job[:source]&.respond_to?(:definition)
            next job unless entities&.respond_to?(:grep)

            validation = Utils::Geometry.validate_cell_space_source_group(job[:source])
            next job if validation[:valid]

            errors << conversion_error(
              job[:source],
              validation[:reason] || 'Invalid CellSpace source geometry'
            )
            nil
          end
          [valid_plan.freeze, errors]
        end

        def validate_plan_targets(plan)
          errors = []
          valid_plan = plan.filter_map do |job|
            target_cell_type, = job[:target] || @fallback_target
            if target_cell_type.nil?
              errors << conversion_error(job[:source], 'CellSpace type is required')
              next
            end

            job
          end
          [valid_plan.freeze, errors]
        end

        def apply_plan(plan)
          snapshot = @runtime_snapshot.call
          operation_started = false
          converted_count = 0
          errors = []

          @apply_guards.call do
            begin
              activate_root_context!
              operation_started = @model.start_operation(@operation_name, true)
              raise 'Failed to start CellSpace conversion operation' unless operation_started

              executor = CellSpaceConversionExecutor.new(
                target_entities: @target_entities,
                converter: @converter,
                preserve_source: @preserve_source,
                logger: @logger,
                labeler: @labeler
              )
              plan.each do |job|
                result = executor.execute(job, fallback_target: @fallback_target)
                if result.converted?
                  converted_count += 1
                else
                  errors.concat(result.errors)
                end
              end

              if converted_count.zero?
                safely_abort_operation if operation_started
                operation_started = false
                safely_restore_runtime(snapshot)
                safely_restore_active_path(success: false)
                next [
                  converted_count,
                  errors,
                  {
                    pair_comparison_count: 0,
                    adjacency_detailed_computation: 0.0,
                    transition_apply: 0.0
                  }
                ]
              end

              adjacency_metrics = @synchronize_all.call || {}
              @apply_lock_policy.call
              @clear_dirty_topology.call
              committed = @model.commit_operation
              raise 'Failed to commit CellSpace conversion operation' if committed == false

              operation_started = false
              safely_restore_active_path(success: true)
              [
                converted_count,
                errors,
                {
                  pair_comparison_count: adjacency_metrics[:pair_comparison_count].to_i,
                  adjacency_detailed_computation: adjacency_metrics[:adjacency_detailed_computation].to_f,
                  transition_apply: adjacency_metrics[:total_duration].to_f
                }
              ]
            rescue StandardError
              safely_abort_operation if operation_started
              safely_restore_runtime(snapshot)
              safely_restore_active_path(success: false)
              raise
            end
          end
        end

        def conversion_error(source, reason)
          {
            group: safe_group_label(source),
            reason: reason.to_s
          }
        end

        def safe_group_label(source)
          @labeler.call(source)
        rescue StandardError
          source.respond_to?(:to_s) ? source.to_s : 'unknown group'
        end

        def activate_root_context!
          return unless @activate_root_context

          activated = @activate_root_context.call
          raise 'Failed to activate root context for CellSpace conversion' unless activated == true
        end

        def safely_abort_operation
          @model.abort_operation
        rescue StandardError => e
          @logger.puts "[IndoorGML] CellSpace conversion abort failed: #{e.class}: #{e.message}"
        end

        def safely_restore_runtime(snapshot)
          @runtime_restore.call(snapshot)
        rescue StandardError => e
          @logger.puts "[IndoorGML] CellSpace conversion runtime restore failed: #{e.class}: #{e.message}"
        end

        def safely_restore_active_path(success:)
          @restore_active_path.call
        rescue StandardError => e
          context = success ? 'after CellSpace conversion commit' : 'during CellSpace conversion rollback'
          @logger.puts "[IndoorGML] Active path restore failed #{context}: #{e.class}: #{e.message}"
        end

        def timed(metrics, key)
          started_at = monotonic_time
          yield
        ensure
          metrics[key] = elapsed_since(started_at) if started_at
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def elapsed_since(started_at)
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        end
      end
    end
  end
end
