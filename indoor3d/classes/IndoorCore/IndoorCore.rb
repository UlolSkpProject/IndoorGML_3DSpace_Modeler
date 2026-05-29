# frozen_string_literal: true

require_relative '../Gml/gml.rb'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      module CellSpaceType
        GENERAL    = 0 unless const_defined?(:GENERAL, false)    # Room
        TRANSFER   = 1 unless const_defined?(:TRANSFER, false)   # Stair / ES / EV
        TRANSITION = 2 unless const_defined?(:TRANSITION, false) # Door / Gate
        CONNECTION = 3 unless const_defined?(:CONNECTION, false) # Corridor
        ANCHOR     = 4 unless const_defined?(:ANCHOR, false)     # Entrance
      end

      class State < GML::AbstractFeature
        attr_reader :sketchup_component_instance
        attr_reader :duality_cell
        attr_reader :position

        @@sketchup_component_definition = nil

        def initialize(cell_space)
          unless cell_space.is_a?(CellSpace)
            raise ArgumentError, 'IndoorCore::CellSpace expected'
          end

          super()

          @duality_cell = cell_space
          @position = cell_space.sketchup_group.bounds.center
          @sketchup_component_instance = create_component_instance(@position)
        end

        def valid?
          @sketchup_component_instance&.valid? == true
        end

        def world_position
          return nil unless valid?

          @sketchup_component_instance.bounds.center
        end

        private

        def create_component_instance(position)
          definition = self.class.sketchup_component_definition
          Sketchup.active_model.active_entities.add_instance(
            definition,
            Geom::Transformation.translation(position)
          )
        end

        def self.sketchup_component_definition
          return @@sketchup_component_definition if @@sketchup_component_definition&.valid?

          model = Sketchup.active_model
          @@sketchup_component_definition = model.definitions.add('IndoorGML_State_Node')

          entities = @@sketchup_component_definition.entities
          circle = entities.add_circle(
            ORIGIN,
            Z_AXIS,
            150.mm,
            16
          )

          face = entities.add_face(circle)
          face.material = state_material

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
          @duality_state = State.new(self)
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

        def initialize(state1 = nil, state2 = nil)
          super()

          @state1 = state1
          @state2 = state2
          @edge = nil
        end

        def update
          erase_edge

          return false unless valid_states?

          point1 = @state1.world_position
          point2 = @state2.world_position

          return false if point1.nil? || point2.nil?

          entities = Sketchup.active_model.active_entities
          @edge = entities.add_cline(point1, point2)

          true
        end

        def valid?
          @edge&.valid? == true
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

      # class PrimalSpaceFeatures < GML::AbstractFeature; end
      # class CellSpaceBoundary < GML::AbstractFeature; end

    end
  end
end