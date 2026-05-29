# frozen_string_literal: true

require_relative '../Gml/gml.rb'
require_relative '../../utils/geometry.rb'
require_relative '../../utils/transformation.rb'
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

        def self.label(value)
          LABELS[value] || LABELS[GENERAL]
        end

        def self.from_label(label)
          LABELS.key(label) || GENERAL
        end
      end

      require_relative '../../utils/materials.rb'

      class State < GML::AbstractFeature
        attr_reader :sketchup_component_instance
        attr_reader :sketchup_component_instance_id
        attr_reader :duality_cell
        attr_reader :position

        STATE_NODE_RADIUS = 2000.mm unless const_defined?(:STATE_NODE_RADIUS, false)

        @@sketchup_component_definition = nil

        def initialize(cell_space, parent_entities, local_position)
          unless cell_space.is_a?(CellSpace)
            raise ArgumentError, 'IndoorCore::CellSpace expected'
          end

          unless local_position.is_a?(Geom::Point3d)
            raise ArgumentError, 'Geom::Point3d local_position expected'
          end

          super()

          @duality_cell = cell_space
          @position = local_position
          @sketchup_component_instance = create_component_instance(@position, parent_entities)
          @sketchup_component_instance_id = @sketchup_component_instance.persistent_id
          @sketchup_component_instance.name = "[Node]-#{@id}"
        end

        def valid?
          @sketchup_component_instance&.valid? == true
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
          @@sketchup_component_definition = model.definitions.add('IndoorGML_State')

          entities = @@sketchup_component_definition.entities
          faces = Utils::Geometry.add_sphere(entities, ORIGIN, STATE_NODE_RADIUS)
          faces.each { |face| face.material = Utils::Materials.state }

          @@sketchup_component_definition
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

        def create_duality_state(parent_entities, local_position)
          @duality_state ||= State.new(self, parent_entities, local_position)
        end

        def valid?
          @sketchup_group&.valid? == true
        end

        def erase!
          @sketchup_group.erase! if valid?
        end

        private

        def validate_sketchup_group!(sketchup_group)
          unless sketchup_group.is_a?(Sketchup::Group) || sketchup_group.is_a?(Sketchup::ComponentInstance)
            raise ArgumentError, 'Sketchup::Group or Sketchup::ComponentInstance expected'
          end

          unless sketchup_group.valid?
            raise ArgumentError, 'Valid Sketchup::Group or Sketchup::ComponentInstance expected'
          end

          unless sketchup_group.respond_to?(:manifold?) && sketchup_group.manifold?
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

        def update(point1, point2)
          erase_edge

          return false unless valid_states?

          return false if point1.nil? || point2.nil?

          entities = @parent_entities || Sketchup.active_model.active_entities
          @edge = entities.add_cline(point1, point2)
          @edge.material = Utils::Materials.transition if @edge.respond_to?(:material=)

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

      require_relative 'IndoorModel.rb'

    end
  end
end
