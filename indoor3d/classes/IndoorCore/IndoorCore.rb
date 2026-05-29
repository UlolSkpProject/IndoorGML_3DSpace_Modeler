# frozen_string_literal: true

require_relative '../Gml/gml.rb'
require_relative '../../utils/geometry.rb'
require_relative '../../utils/transformation.rb'
require_relative 'Observers.rb'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      module CellSpaceType
        GENERAL    = 0 unless const_defined?(:GENERAL, false)
        TRANSFER   = 1 unless const_defined?(:TRANSFER, false)
        TRANSITION = 2 unless const_defined?(:TRANSITION, false)
        CONNECTION = 3 unless const_defined?(:CONNECTION, false)
        ANCHOR     = 4 unless const_defined?(:ANCHOR, false)

        LABELS = {
          GENERAL => 'GeneralSpace',
          TRANSFER => 'TransferSpace',
          TRANSITION => 'TransitionSpace',
          CONNECTION => 'ConnectionSpace',
          ANCHOR => 'AnchorSpace'
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
        attr_reader :transitions

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
          @transitions = []
          @sketchup_component_instance = create_component_instance(@position, parent_entities)
          @sketchup_component_instance_id = @sketchup_component_instance.persistent_id
          @sketchup_component_instance.name = "[Node]-#{@id}"
        end

        def update_position(local_position)
          unless local_position.is_a?(Geom::Point3d)
            raise ArgumentError, 'Geom::Point3d local_position expected'
          end

          @position = local_position
        end

        def add_transition(transition)
          @transitions << transition unless @transitions.include?(transition)
        end

        def remove_transition(transition)
          @transitions.delete(transition)
        end

        def transition_ids
          @transitions.select(&:valid?).map(&:id)
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
        attr_reader :cell1
        attr_reader :cell2
        attr_reader :edge

        TRANSITION_RADIUS = State::STATE_NODE_RADIUS * 0.5 unless const_defined?(:TRANSITION_RADIUS, false)
        TRANSITION_BASE_HEIGHT = 1.0 unless const_defined?(:TRANSITION_BASE_HEIGHT, false)

        @@sketchup_component_definition = nil

        def initialize(state1 = nil, state2 = nil, parent_entities = nil, cell1: nil, cell2: nil)
          super()

          @state1 = state1
          @state2 = state2
          @cell1 = cell1
          @cell2 = cell2
          @parent_entities = parent_entities
          @edge = nil
        end

        def update(point1, point2)
          return false unless valid_states?
          return false if point1.nil? || point2.nil?

          transformation = cylinder_transformation(point1, point2)
          return false if transformation.nil?

          if @edge&.valid?
            @edge.transformation = transformation
          else
            entities = @parent_entities || Sketchup.active_model.active_entities
            @edge = entities.add_instance(self.class.sketchup_component_definition, transformation)
            @edge.name = "[Transition]-#{@id}"
          end
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

        def cylinder_transformation(point1, point2)
          direction = point1.vector_to(point2)
          length = direction.length
          return nil if length <= 0.001

          z_axis = direction
          z_axis.normalize!
          x_axis = perpendicular_axis(z_axis)
          y_axis = z_axis.cross(x_axis)
          y_axis.normalize!

          midpoint = Geom::Point3d.new(
            (point1.x + point2.x) / 2.0,
            (point1.y + point2.y) / 2.0,
            (point1.z + point2.z) / 2.0
          )

          scaled_z_axis = Geom::Vector3d.new(
            z_axis.x * length,
            z_axis.y * length,
            z_axis.z * length
          )

          Geom::Transformation.new(
            [
              x_axis.x, x_axis.y, x_axis.z, 0.0,
              y_axis.x, y_axis.y, y_axis.z, 0.0,
              scaled_z_axis.x, scaled_z_axis.y, scaled_z_axis.z, 0.0,
              midpoint.x, midpoint.y, midpoint.z, 1.0
            ]
          )
        end

        def perpendicular_axis(z_axis)
          seed =
            if z_axis.parallel?(Z_AXIS)
              X_AXIS
            else
              Z_AXIS
            end
          x_axis = seed.cross(z_axis)
          x_axis.normalize!
          x_axis
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

        def self.sketchup_component_definition
          return @@sketchup_component_definition if @@sketchup_component_definition&.valid?

          model = Sketchup.active_model
          @@sketchup_component_definition = model.definitions.add('IndoorGML_Transition')

          entities = @@sketchup_component_definition.entities
          faces = Utils::Geometry.add_cylinder(
            entities,
            TRANSITION_RADIUS,
            TRANSITION_BASE_HEIGHT
          )
          faces.each { |face| face.material = Utils::Materials.transition }

          @@sketchup_component_definition
        end
      end

      require_relative 'IndoorModel.rb'

    end
  end
end
