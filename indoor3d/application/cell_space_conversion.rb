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

      class BulkCellSpaceConversionProgress
        def initialize(start:, update:, finish:)
          @start = start
          @update = update
          @finish = finish
        end

        def start(total, message)
          @start.call(total, message) if @start
        end

        def update(current, message)
          @update.call(current, message) if @update
        end

        def finish
          @finish.call if @finish
        end
      end

      class BulkCellSpaceConversionService
        Result = Struct.new(:converted_count, :errors, :metrics, keyword_init: true)

        def initialize(model:, jobs:, fallback_target:, target_entities:, converter:, synchronize_all:, apply_lock_policy:, runtime_snapshot:, runtime_restore:, apply_guards:, restore_active_path:, activate_root_context:, clear_dirty_topology:, progress:, logger: Logger, labeler: nil, preserve_source: nil, operation_name: 'Convert Solid Groups to CellSpace')
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
          @progress = progress
          @logger = logger
          @labeler = labeler || proc { |entity| entity.respond_to?(:name) ? entity.name.to_s : entity.to_s }
          @preserve_source = preserve_source
          @operation_name = operation_name
        end

        def call
          started_at = monotonic_time
          metrics = {}
          progress_total = [@jobs.length + 4, 1].max
          @progress.start(progress_total, 'Preparing conversion jobs')
          plan = timed(metrics, :job_preparation) { prepare_plan }
          @progress.update(1, 'Validating geometry')
          timed(metrics, :geometry_validation) { validate_plan_geometry(plan) }
          @progress.update(2, 'Computing adjacency plan')
          timed(metrics, :adjacency_candidate_generation) { validate_plan_targets(plan) }
          @progress.update(3, 'Applying CellSpaces...')
          converted_count, apply_metrics = timed(metrics, :cell_space_entity_apply) { apply_plan(plan) }
          metrics.merge!(apply_metrics)
          metrics[:total_duration] = elapsed_since(started_at)
          @progress.update(progress_total, 'Complete')
          Result.new(converted_count: converted_count, errors: [], metrics: metrics)
        ensure
          @progress.finish
        end

        private

        def prepare_plan
          raise ArgumentError, 'No valid solid groups were available for conversion' if @jobs.empty?

          @jobs.each_with_index.map do |job, index|
            source = job[:source]
            unless source&.respond_to?(:valid?) && source.valid?
              raise ArgumentError, "Conversion source is no longer valid: #{@labeler.call(source)}"
            end

            job.merge(job_id: "cell_space_conversion_#{index}")
          end.freeze
        end

        def validate_plan_geometry(plan)
          return unless defined?(Utils::Geometry) && Utils::Geometry.respond_to?(:validate_cell_space_source_group)

          plan.each do |job|
            entities = job[:source]&.definition&.entities if job[:source]&.respond_to?(:definition)
            next unless entities&.respond_to?(:grep)

            validation = Utils::Geometry.validate_cell_space_source_group(job[:source])
            next if validation[:valid]

            raise ArgumentError, validation[:reason] || "Invalid CellSpace source geometry: #{@labeler.call(job[:source])}"
          end
        end

        def validate_plan_targets(plan)
          plan.each do |job|
            target_cell_type, = job[:target] || @fallback_target
            raise ArgumentError, "CellSpace type is required for #{@labeler.call(job[:source])}" if target_cell_type.nil?
          end
        end

        def apply_plan(plan)
          snapshot = @runtime_snapshot.call
          operation_started = false
          converted_count = 0

          @apply_guards.call do
            begin
              @activate_root_context.call if @activate_root_context
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
                executor.execute!(job, fallback_target: @fallback_target)
                converted_count += 1
              end

              adjacency_metrics = @synchronize_all.call || {}
              @apply_lock_policy.call
              @clear_dirty_topology.call
              @restore_active_path.call
              committed = @model.commit_operation
              raise 'Failed to commit CellSpace conversion operation' if committed == false

              operation_started = false
              [
                converted_count,
                {
                  pair_comparison_count: adjacency_metrics[:pair_comparison_count].to_i,
                  adjacency_detailed_computation: adjacency_metrics[:adjacency_detailed_computation].to_f,
                  transition_apply: adjacency_metrics[:total_duration].to_f
                }
              ]
            rescue StandardError => e
              safely_restore_active_path
              @model.abort_operation if operation_started
              @runtime_restore.call(snapshot)
              raise e
            end
          end
        end

        def safely_restore_active_path
          @restore_active_path.call
        rescue StandardError => e
          @logger.puts "[IndoorGML] Active path restore failed during CellSpace conversion rollback: #{e.class}: #{e.message}"
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
