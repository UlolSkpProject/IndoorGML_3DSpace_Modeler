# frozen_string_literal: true

require_relative '../../definition'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class AttributeSerializer
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml'
        INDOOR_GML_ATTRIBUTE_KEYS = %w[
          feature
          name
          indoor_gml_version
          id
          cell_type
          category_code
          storey
          duality_state_id
          navigation_class
          navigation_class_code_space
          navigation_function
          navigation_function_code_space
          navigation_usage
          navigation_usage_code_space
        ].freeze

        def initialize(dictionary_name: ATTRIBUTE_DICTIONARY_NAME, indoor_gml_version: Definition::INDOOR_GML_VERSION)
          @dictionary_name = dictionary_name
          @indoor_gml_version = indoor_gml_version
        end

        def attribute(entity, key)
          entity.get_attribute(@dictionary_name, key)
        rescue StandardError
          nil
        end

        def feature(entity)
          attribute(entity, 'feature')
        end

        def indoor_gml_entity?(entity)
          feature(entity).to_s.length.positive?
        end

        def converted_group?(sketchup_group)
          feature(sketchup_group) == 'CellSpace'
        end

        # Bulk conversion can request many logically identical CellSpace writes while
        # topology creates/updates transitions. Keep the optimization explicitly
        # scoped to the caller-owned batch: normal create/edit/load persistence keeps
        # the existing eager-write behavior.
        #
        # When +defer_writes+ is true, write requests are acknowledged without
        # mutating SketchUp attributes until the caller explicitly enters a flush
        # section. Successful flush writes populate the persisted-signature cache, so
        # later topology writes with unchanged serialized state become no-ops for the
        # rest of the same batch.
        def with_cell_space_write_dedup(defer_writes: false)
          previous_cache = @cell_space_write_dedup_cache
          previous_defer = @defer_cell_space_writes
          @cell_space_write_dedup_cache = {}
          @defer_cell_space_writes = defer_writes == true
          yield
        ensure
          @cell_space_write_dedup_cache = previous_cache
          @defer_cell_space_writes = previous_defer
        end

        def with_cell_space_write_flush
          previous_defer = @defer_cell_space_writes
          @defer_cell_space_writes = false
          yield
        ensure
          @defer_cell_space_writes = previous_defer
        end

        def write_space_features(group, feature)
          return false unless valid_entity?(group)

          write_attributes(group) do
            group.set_attribute(@dictionary_name, 'feature', feature)
            group.set_attribute(@dictionary_name, 'name', group.name)
            group.set_attribute(@dictionary_name, 'indoor_gml_version', @indoor_gml_version)
          end
        end

        def write_cell_space_and_state(cell_space)
          write_cell_space(cell_space)
        end

        def write_cell_space(cell_space)
          group = cell_space.valid_sketchup_group
          return false unless group
          return true if @defer_cell_space_writes == true

          cache_key = group.object_id
          signature = cell_space_write_signature(cell_space)
          cache = @cell_space_write_dedup_cache
          return true if cache && cache[cache_key] == signature

          written = write_attributes(group) do
            group.set_attribute(@dictionary_name, 'feature', 'CellSpace')
            group.set_attribute(@dictionary_name, 'id', cell_space.id)
            group.set_attribute(@dictionary_name, 'cell_type', CellSpaceType.label(cell_space.cell_type))
            group.set_attribute(@dictionary_name, 'category_code', cell_space.category_code)
            write_navigation_attributes(group, cell_space)
            group.set_attribute(@dictionary_name, 'storey', cell_space.storey)
            group.set_attribute(@dictionary_name, 'duality_state_id', cell_space.duality_state.id) if cell_space.duality_state
          end

          cache[cache_key] = signature if written && cache
          written
        end

        def write_state(state)
          return false unless state&.duality_cell&.valid?

          write_cell_space(state.duality_cell)
        end

        def write_transition(transition)
          return false unless transition

          results = []
          results << write_state(transition.state1) if transition.state1
          results << write_state(transition.state2) if transition.state2
          results.any? && results.all?
        end

        def copy_indoor_attributes(source, target)
          return false unless valid_entity?(source)
          return false unless valid_entity?(target)

          dictionary = source.attribute_dictionary(@dictionary_name)
          return false if dictionary.nil?

          write_attributes(target) do
            dictionary.each_pair do |key, value|
              target.set_attribute(@dictionary_name, key, value)
            end
          end
        end

        def clear_indoor_gml_attributes(entity)
          return false unless valid_entity?(entity)
          return false unless entity.respond_to?(:delete_attribute)

          keys = indoor_gml_attribute_keys(entity)
          return false if keys.empty?

          keys.each { |key| entity.delete_attribute(@dictionary_name, key) }
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Attribute cleanup failed: #{e.class}: #{e.message}"
          false
        end

        private

        def cell_space_write_signature(cell_space)
          state = cell_space.duality_state
          [
            cell_space.id,
            cell_space.cell_type,
            cell_space.category_code,
            cell_space.storey,
            state&.id,
            cell_space.navigation_class,
            cell_space.navigation_class_code_space,
            cell_space.navigation_function,
            cell_space.navigation_function_code_space,
            cell_space.navigation_usage,
            cell_space.navigation_usage_code_space
          ].freeze
        end

        def indoor_gml_attribute_keys(entity)
          dictionary = entity.attribute_dictionary(@dictionary_name) if entity.respond_to?(:attribute_dictionary)
          if dictionary&.respond_to?(:each_pair)
            keys = []
            dictionary.each_pair { |key, _value| keys << key.to_s }
            return keys
          end

          INDOOR_GML_ATTRIBUTE_KEYS.select do |key|
            !attribute(entity, key).nil?
          end
        end

        def valid_entity?(entity)
          return false if entity.nil?
          return true unless entity.respond_to?(:valid?)

          entity.valid? == true
        rescue StandardError
          false
        end

        def write_attributes(entity)
          return false unless valid_entity?(entity)

          yield
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Attribute write failed: #{e.class}: #{e.message}"
          false
        end

        def write_navigation_attributes(group, cell_space)
          if cell_space.navigable?
            semantic = NavigationSemanticResolver.resolve(cell_space)
            group.set_attribute(@dictionary_name, 'navigation_class', semantic.class_value)
            write_optional_attribute(group, 'navigation_class_code_space', semantic.class_code_space)
            group.set_attribute(@dictionary_name, 'navigation_function', semantic.function_value)
            write_optional_attribute(group, 'navigation_function_code_space', semantic.function_code_space)
            group.set_attribute(@dictionary_name, 'navigation_usage', semantic.usage_value)
            write_optional_attribute(group, 'navigation_usage_code_space', semantic.usage_code_space)
            return
          end

          %w[
            navigation_class
            navigation_class_code_space
            navigation_function
            navigation_function_code_space
            navigation_usage
            navigation_usage_code_space
          ].each do |key|
            group.delete_attribute(@dictionary_name, key) if group.respond_to?(:delete_attribute)
          end
        end

        def write_optional_attribute(group, key, value)
          if value.to_s.empty?
            group.delete_attribute(@dictionary_name, key) if group.respond_to?(:delete_attribute)
          else
            group.set_attribute(@dictionary_name, key, value)
          end
        end
      end

    end
  end
end
