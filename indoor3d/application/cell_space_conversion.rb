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
          source = nil
          erase_original_after_success = false
          cleanup_source_on_failure = false
          target_cell_type, target_category_code = job[:target] || fallback_target
          source, erase_original_after_success, cleanup_source_on_failure = prepare_source(job)
          @converter.call(source, target_cell_type, target_category_code)
          job[:source].erase! if erase_original_after_success && job[:source]&.valid?
          cleanup_empty_ancestors(job)
          Result.new(converted: true, errors: [])
        rescue StandardError => e
          @logger.puts "[IndoorGML] CellSpace conversion failed: #{e.class}: #{e.message}"
          cleanup_failed_source(source) if cleanup_source_on_failure
          Result.new(
            converted: false,
            errors: [{ group: @labeler.call(job[:source]), reason: e.message }]
          )
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
    end
  end
end
