# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class AttributeSerializer
        DICTIONARY_NAME = 'IndoorGml'
        INDOOR_GML_VERSION = '1.1'

        def initialize(dictionary_name: DICTIONARY_NAME, indoor_gml_version: INDOOR_GML_VERSION)
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
          return unless group&.valid?

          group.set_attribute(@dictionary_name, 'feature', feature)
          group.set_attribute(@dictionary_name, 'name', group.name)
          group.set_attribute(@dictionary_name, 'indoor_gml_version', @indoor_gml_version)
        end

        def write_cell_space_and_state(cell_space)
          write_cell_space(cell_space)
          write_state_header(cell_space.duality_state, cell_space)
          write_state(cell_space.duality_state)
        end

        def write_cell_space(cell_space)
          group = cell_space.sketchup_group

          group.set_attribute(@dictionary_name, 'feature', 'CellSpace')
          group.set_attribute(@dictionary_name, 'id', cell_space.id)
          group.set_attribute(@dictionary_name, 'name', group.name)
          group.set_attribute(@dictionary_name, 'cell_type', CellSpaceType.label(cell_space.cell_type))
          group.set_attribute(@dictionary_name, 'duality_state_id', cell_space.duality_state.id) if cell_space.duality_state
          group.set_attribute(@dictionary_name, 'indoor_gml_version', @indoor_gml_version)
        end

        def write_state(state)
          return unless state&.valid?

          component = state.sketchup_component_instance
          component.set_attribute(@dictionary_name, 'feature', 'State')
          component.set_attribute(@dictionary_name, 'id', state.id)
          component.set_attribute(@dictionary_name, 'name', state.name)
          component.set_attribute(@dictionary_name, 'duality_cell_id', state.duality_cell.id)
          component.set_attribute(@dictionary_name, 'transition_ids', state.transition_ids)
          component.set_attribute(@dictionary_name, 'position_x', state.position.x.to_f)
          component.set_attribute(@dictionary_name, 'position_y', state.position.y.to_f)
          component.set_attribute(@dictionary_name, 'position_z', state.position.z.to_f)
          component.set_attribute(@dictionary_name, 'indoor_gml_version', @indoor_gml_version)
        end

        def write_transition(transition)
          return unless transition.edge&.valid?

          transition.edge.set_attribute(@dictionary_name, 'feature', 'Transition')
          transition.edge.set_attribute(@dictionary_name, 'id', transition.id)
          transition.edge.set_attribute(@dictionary_name, 'name', transition.name)
          transition.edge.set_attribute(@dictionary_name, 'state1_id', transition.state1.id)
          transition.edge.set_attribute(@dictionary_name, 'state2_id', transition.state2.id)
          transition.edge.set_attribute(@dictionary_name, 'cell1_id', transition.cell1.id) if transition.cell1
          transition.edge.set_attribute(@dictionary_name, 'cell2_id', transition.cell2.id) if transition.cell2
          transition.edge.set_attribute(@dictionary_name, 'indoor_gml_version', @indoor_gml_version)
        end

        def copy_indoor_attributes(source, target)
          dictionary = source.attribute_dictionary(@dictionary_name)
          return if dictionary.nil?

          dictionary.each_pair do |key, value|
            target.set_attribute(@dictionary_name, key, value)
          end
        end

        private

        def write_state_header(state, cell_space)
          component = state.sketchup_component_instance
          component.set_attribute(@dictionary_name, 'feature', 'State')
          component.set_attribute(@dictionary_name, 'id', state.id)
          component.set_attribute(@dictionary_name, 'name', state.name)
          component.set_attribute(@dictionary_name, 'duality_cell_id', cell_space.id)
          component.set_attribute(@dictionary_name, 'indoor_gml_version', @indoor_gml_version)
        end
      end

    end
  end
end
