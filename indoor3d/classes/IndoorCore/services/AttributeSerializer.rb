# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class AttributeSerializer
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml'
        INDOOR_GML_VERSION = '1.0'

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
            group.set_attribute(@dictionary_name, 'name', group.name)
            group.set_attribute(@dictionary_name, 'cell_type', CellSpaceType.label(cell_space.cell_type))
            group.set_attribute(@dictionary_name, 'category_code', cell_space.category_code)
            group.set_attribute(@dictionary_name, 'category_label', cell_space.category_label)
            group.set_attribute(@dictionary_name, 'category_code_space', cell_space.category_code_space)
            group.set_attribute(@dictionary_name, 'category_standard', cell_space.category_standard)
            group.set_attribute(@dictionary_name, 'duality_state_id', cell_space.duality_state.id) if cell_space.duality_state
            if cell_space.duality_state
              group.set_attribute(@dictionary_name, 'state_position_x', cell_space.duality_state.position.x.to_f)
              group.set_attribute(@dictionary_name, 'state_position_y', cell_space.duality_state.position.y.to_f)
              group.set_attribute(@dictionary_name, 'state_position_z', cell_space.duality_state.position.z.to_f)
              group.set_attribute(@dictionary_name, 'state_transition_ids', cell_space.duality_state.transition_ids)
            end
            group.set_attribute(@dictionary_name, 'indoor_gml_version', @indoor_gml_version)
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
          entity&.valid? == true
        rescue StandardError
          false
        end

        def write_attributes(entity)
          return false unless valid_entity?(entity)

          yield
          true
        rescue StandardError => e
          puts "[IndoorGML] Attribute write failed: #{e.class}: #{e.message}"
          false
        end
      end

    end
  end
end
