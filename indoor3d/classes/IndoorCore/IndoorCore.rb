# frozen_string_literal: true

require_relative '../Gml/gml.rb'
require_relative '../../utils/geometry.rb'
require_relative 'Observers.rb'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      module CellSpaceType
        GENERAL    = 0 unless const_defined?(:GENERAL, false)    # Room
        TRANSFER   = 1 unless const_defined?(:TRANSFER, false)   # Stair / ES / EV
        TRANSITION = 2 unless const_defined?(:TRANSITION, false) # Door / Gate
        CONNECTION = 3 unless const_defined?(:CONNECTION, false) # Corridor
        ANCHOR     = 4 unless const_defined?(:ANCHOR, false)     # Entrance

        LABELS = {
          GENERAL => 'General',
          TRANSFER => 'Transfer',
          TRANSITION => 'Transition',
          CONNECTION => 'Connection',
          ANCHOR => 'Anchor'
        }.freeze unless const_defined?(:LABELS, false)

        def self.values
          LABELS.keys
        end

        def self.label(value)
          LABELS[value] || LABELS[GENERAL]
        end

        def self.from_label(label)
          LABELS.key(label) || GENERAL
        end
      end

      class State < GML::AbstractFeature
        attr_reader :sketchup_component_instance
        attr_reader :sketchup_component_instance_id
        attr_reader :duality_cell
        attr_reader :position

        @@sketchup_component_definition = nil

        def initialize(cell_space, parent_entities = nil)
          unless cell_space.is_a?(CellSpace)
            raise ArgumentError, 'IndoorCore::CellSpace expected'
          end

          super()

          @duality_cell = cell_space
          @position = cell_space.sketchup_group.bounds.center
          @sketchup_component_instance = create_component_instance(@position, parent_entities)
          @sketchup_component_instance_id = @sketchup_component_instance.persistent_id
        end

        def valid?
          @sketchup_component_instance&.valid? == true
        end

        def world_position
          return nil unless valid?

          @sketchup_component_instance.bounds.center
        end

        def move_to(position)
          return false unless valid?

          current_position = world_position
          return false if current_position.nil?

          vector = current_position.vector_to(position)
          return true if vector.length <= 0.001

          @sketchup_component_instance.transform!(Geom::Transformation.translation(vector))
          @position = position

          true
        end

        def erase!
          @sketchup_component_instance.erase! if valid?
        end

        private

        def create_component_instance(position, parent_entities)
          definition = self.class.sketchup_component_definition
          entities = parent_entities || Sketchup.active_model.active_entities
          entities.add_instance(
            definition,
            Geom::Transformation.translation(position)
          )
        end

        def self.sketchup_component_definition
          return @@sketchup_component_definition if @@sketchup_component_definition&.valid?

          model = Sketchup.active_model
          @@sketchup_component_definition = model.definitions.add('IndoorGML_State_Node')

          entities = @@sketchup_component_definition.entities
          faces = Utils::Geometry.add_sphere(entities, ORIGIN, 150.mm)
          faces.each { |face| face.material = state_material }

          @@sketchup_component_definition
        end

        def self.state_material
          model = Sketchup.active_model
          material = model.materials['IndoorGML_State']

          unless material
            material = model.materials.add('IndoorGML_State')
            material.color = Sketchup::Color.new(0, 0, 255)
          end

          material
        end
      end

      class CellSpace < GML::AbstractFeature
        attr_reader :sketchup_group
        attr_reader :sketchup_group_id
        attr_accessor :cell_type
        attr_reader :duality_state

        def initialize(sketchup_group, cell_type = CellSpaceType::GENERAL)
          validate_sketchup_group!(sketchup_group)

          super()

          @sketchup_group = sketchup_group
          @sketchup_group_id = sketchup_group.persistent_id
          @cell_type = cell_type
          @duality_state = nil
        end

        def create_duality_state(parent_entities = nil)
          @duality_state ||= State.new(self, parent_entities)
        end

        def valid?
          @sketchup_group&.valid? == true
        end

        def solid?
          valid? && @sketchup_group.manifold?
        end

        def center
          return nil unless valid?

          @sketchup_group.bounds.center
        end

        def move_center_to(position)
          return false unless valid?

          current_center = center
          return false if current_center.nil?

          vector = current_center.vector_to(position)
          return true if vector.length <= 0.001

          @sketchup_group.transform!(Geom::Transformation.translation(vector))

          true
        end

        def erase!
          @sketchup_group.erase! if valid?
        end

        private

        def validate_sketchup_group!(sketchup_group)
          unless sketchup_group.is_a?(Sketchup::Group)
            raise ArgumentError, 'Sketchup::Group expected'
          end

          unless sketchup_group.valid?
            raise ArgumentError, 'Valid Sketchup::Group expected'
          end

          unless sketchup_group.manifold?
            raise ArgumentError, 'Solid Group expected'
          end
        end
      end

      class Transition < GML::AbstractFeature
        attr_reader :state1
        attr_reader :state2
        attr_reader :edge

        def initialize(state1 = nil, state2 = nil, parent_entities = nil)
          super()

          @state1 = state1
          @state2 = state2
          @parent_entities = parent_entities
          @edge = nil
        end

        def update
          erase_edge

          return false unless valid_states?

          point1 = @state1.world_position
          point2 = @state2.world_position

          return false if point1.nil? || point2.nil?

          entities = @parent_entities || Sketchup.active_model.active_entities
          @edge = entities.add_cline(point1, point2)

          true
        end

        def valid?
          @edge&.valid? == true
        end

        def connected_to?(state)
          @state1 == state || @state2 == state
        end

        def erase!
          erase_edge
        end

        private

        def erase_edge
          @edge.erase! if @edge&.valid?
          @edge = nil
        end

        def valid_states?
          return false if @state1.nil? || @state2.nil?
          return false if @state1 == @state2
          return false unless @state1.is_a?(State)
          return false unless @state2.is_a?(State)
          return false unless @state1.valid?
          return false unless @state2.valid?

          true
        end
      end

      class IndoorModel
        PRIMAL_GROUP_NAME = 'IndoorGML_PrimalSpaceFeatures'
        DUAL_GROUP_NAME = 'IndoorGML_DualSpaceFeatures'

        attr_reader :cell_spaces
        attr_reader :states
        attr_reader :transitions
        attr_reader :primal_group
        attr_reader :dual_group

        def self.current
          @current ||= new
        end

        def initialize
          @cell_spaces = []
          @states = []
          @transitions = []
          @cell_spaces_by_entity = {}
          @cell_spaces_by_entity_id = {}
          @states_by_entity = {}
          @states_by_entity_id = {}
          @cell_space_observer = CellSpaceObserver.new(self)
          @state_observer = StateObserver.new(self)
          @syncing = false
          @erasing = false
          @primal_group = nil
          @dual_group = nil
        end

        def convert_group_to_cell_space(sketchup_group, cell_type = CellSpaceType::GENERAL)
          ensure_space_groups
          raise ArgumentError, 'Group is already converted to CellSpace' if converted_group?(sketchup_group)

          cell_group = place_cell_group(sketchup_group)
          cell_space = CellSpace.new(cell_group, cell_type)
          state = cell_space.create_duality_state(@dual_group.entities)

          register_cell_space(cell_space)
          register_state(state)
          write_attributes(cell_space)

          cell_space
        end

        def connect_states(state1, state2)
          ensure_space_groups

          transition = Transition.new(state1, state2, @dual_group.entities)
          return nil unless transition.update

          @transitions << transition
          transition
        end

        def cell_space_changed(entity)
          return if @syncing || @erasing

          cell_space = find_cell_space_for_entity(entity)
          return if cell_space.nil? || !cell_space.valid?

          sync do
            state = cell_space.duality_state
            state.move_to(cell_space.center) if state&.valid?
            update_transitions_for_state(state)
          end
        end

        def state_changed(entity)
          return if @syncing || @erasing

          state = find_state_for_entity(entity)
          return if state.nil? || !state.valid?

          sync do
            cell_space = state.duality_cell
            cell_space.move_center_to(state.world_position) if cell_space&.valid?
            update_transitions_for_state(state)
          end
        end

        def cell_space_erased(entity)
          return if @erasing

          cell_space = find_cell_space_for_entity(entity)
          erase_cell_space(cell_space, erase_sketchup_group: false)
        end

        def state_erased(entity)
          return if @erasing

          state = find_state_for_entity(entity)
          erase_state(state, erase_sketchup_instance: false)
        end

        def erase_cell_space(cell_space, erase_sketchup_group: true)
          return if cell_space.nil?

          erase_guard do
            state = cell_space.duality_state
            erase_transitions_for_state(state)
            state.erase! if state&.valid?
            unregister_state(state)
            cell_space.erase! if erase_sketchup_group && cell_space.valid?
            unregister_cell_space(cell_space)
          end
        end

        def erase_state(state, erase_sketchup_instance: true)
          return if state.nil?

          erase_guard do
            cell_space = state.duality_cell
            erase_transitions_for_state(state)
            cell_space.erase! if cell_space&.valid?
            state.erase! if erase_sketchup_instance && state.valid?
            unregister_cell_space(cell_space)
            unregister_state(state)
          end
        end

        def update_transitions_for_state(state)
          return if state.nil?

          @transitions.each do |transition|
            transition.update if transition.connected_to?(state)
          end
        end

        private

        def ensure_space_groups
          model = Sketchup.active_model
          entities = model.active_entities

          @primal_group = find_group(entities, PRIMAL_GROUP_NAME)
          unless @primal_group&.valid?
            @primal_group = entities.add_group
            @primal_group.name = PRIMAL_GROUP_NAME
          end

          @dual_group = find_group(entities, DUAL_GROUP_NAME)
          unless @dual_group&.valid?
            @dual_group = entities.add_group
            @dual_group.name = DUAL_GROUP_NAME
          end
        end

        def find_group(entities, name)
          entities.grep(Sketchup::Group).find { |group| group.valid? && group.name == name }
        end

        def place_cell_group(sketchup_group)
          return sketchup_group if inside_primal_group?(sketchup_group)

          begin
            nested_container = @primal_group.entities.add_group(sketchup_group)
            nested_container.name = 'CellSpace'
            nested_group = nested_container.entities.grep(Sketchup::Group).find(&:valid?)
            return nested_group if nested_group
          rescue StandardError
            # Fall through to wrapping in the active context.
          end

          begin
            wrapped_group = Sketchup.active_model.active_entities.add_group(sketchup_group)
            wrapped_group.name = "#{PRIMAL_GROUP_NAME}_CellSpace"
            nested_group = wrapped_group.entities.grep(Sketchup::Group).find(&:valid?)
            return nested_group if nested_group
          rescue StandardError
            # Some nested editing contexts cannot re-parent entities safely.
          end

          sketchup_group
        end

        def inside_primal_group?(sketchup_group)
          sketchup_group.parent == @primal_group.entities
        rescue StandardError
          false
        end

        def register_cell_space(cell_space)
          @cell_spaces << cell_space
          @cell_spaces_by_entity[cell_space.sketchup_group] = cell_space
          @cell_spaces_by_entity_id[cell_space.sketchup_group.persistent_id] = cell_space
          cell_space.sketchup_group.add_observer(@cell_space_observer)
        end

        def register_state(state)
          @states << state
          @states_by_entity[state.sketchup_component_instance] = state
          @states_by_entity_id[state.sketchup_component_instance.persistent_id] = state
          state.sketchup_component_instance.add_observer(@state_observer)
        end

        def unregister_cell_space(cell_space)
          return if cell_space.nil?

          @cell_spaces.delete(cell_space)
          @cell_spaces_by_entity.delete(cell_space.sketchup_group)
          @cell_spaces_by_entity_id.delete(cell_space.sketchup_group_id)
        end

        def unregister_state(state)
          return if state.nil?

          @states.delete(state)
          @states_by_entity.delete(state.sketchup_component_instance)
          @states_by_entity_id.delete(state.sketchup_component_instance_id)
        end

        def erase_transitions_for_state(state)
          return if state.nil?

          @transitions.delete_if do |transition|
            next false unless transition.connected_to?(state)

            transition.erase!
            true
          end
        end

        def write_attributes(cell_space)
          group = cell_space.sketchup_group
          state = cell_space.duality_state.sketchup_component_instance

          group.set_attribute('IndoorGML', 'feature', 'CellSpace')
          group.set_attribute('IndoorGML', 'id', cell_space.id)
          group.set_attribute('IndoorGML', 'cell_type', CellSpaceType.label(cell_space.cell_type))
          state.set_attribute('IndoorGML', 'feature', 'State')
          state.set_attribute('IndoorGML', 'id', cell_space.duality_state.id)
          state.set_attribute('IndoorGML', 'duality_cell_id', cell_space.id)
        end

        def converted_group?(sketchup_group)
          sketchup_group.get_attribute('IndoorGML', 'feature') == 'CellSpace'
        end

        def find_cell_space_for_entity(entity)
          @cell_spaces_by_entity[entity] || @cell_spaces_by_entity_id[entity.persistent_id]
        rescue StandardError
          @cell_spaces_by_entity[entity]
        end

        def find_state_for_entity(entity)
          @states_by_entity[entity] || @states_by_entity_id[entity.persistent_id]
        rescue StandardError
          @states_by_entity[entity]
        end

        def sync
          @syncing = true
          yield
        ensure
          @syncing = false
        end

        def erase_guard
          @erasing = true
          yield
        ensure
          @erasing = false
        end
      end

      # class PrimalSpaceFeatures < GML::AbstractFeature; end
      # class CellSpaceBoundary < GML::AbstractFeature; end

    end
  end
end
