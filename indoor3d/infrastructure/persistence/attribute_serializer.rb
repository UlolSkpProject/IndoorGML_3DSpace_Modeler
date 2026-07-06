# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class AttributeSerializer
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml'
        INDOOR_GML_VERSION = '1.0.3'

        def initialize(dictionary_name: ATTRIBUTE_DICTIONARY_NAME, indoor_gml_version: INDOOR_GML_VERSION)
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

          write_attributes(group) do
            group.set_attribute(@dictionary_name, 'feature', 'CellSpace')
            group.set_attribute(@dictionary_name, 'id', cell_space.id)
            group.set_attribute(@dictionary_name, 'cell_type', CellSpaceType.label(cell_space.cell_type))
            group.set_attribute(@dictionary_name, 'category_code', cell_space.category_code)
            write_navigation_attributes(group, cell_space)
            group.set_attribute(@dictionary_name, 'storey', cell_space.storey)
            group.set_attribute(@dictionary_name, 'duality_state_id', cell_space.duality_state.id) if cell_space.duality_state
          end
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

        private

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
            group.set_attribute(@dictionary_name, 'navigation_class_code_space', semantic.class_code_space)
            group.set_attribute(@dictionary_name, 'navigation_function', semantic.function_value)
            group.set_attribute(@dictionary_name, 'navigation_function_code_space', semantic.function_code_space)
            group.set_attribute(@dictionary_name, 'navigation_usage', semantic.usage_value)
            group.set_attribute(@dictionary_name, 'navigation_usage_code_space', semantic.usage_code_space)
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
      end

    end
  end
end
