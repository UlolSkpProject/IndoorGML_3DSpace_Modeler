# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class Transition < GML::AbstractFeature
        attr_reader :state1
        attr_reader :state2
        attr_reader :cell1
        attr_reader :cell2
        attr_reader :edge
        attr_accessor :editable

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
          @editable = false
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

        def self.restore(edge, state1, state2, cell1: nil, cell2: nil, id: nil, name: nil)
          unless edge.is_a?(Sketchup::ComponentInstance)
            raise ArgumentError, 'Sketchup::ComponentInstance expected'
          end

          transition = allocate
          transition.send(:initialize_restored, edge, state1, state2, cell1, cell2, id, name)
          transition
        end

        private

        def initialize_restored(edge, state1, state2, cell1, cell2, id, name)
          @state1 = state1
          @state2 = state2
          @cell1 = cell1
          @cell2 = cell2
          @parent_entities = edge.parent.respond_to?(:entities) ? edge.parent.entities : nil
          @edge = edge
          @editable = false
          @id = id unless id.to_s.empty?
          @name = name.to_s
        end

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
          radius_scale = State.display_radius / State::STATE_NODE_RADIUS
          scaled_x_axis = Geom::Vector3d.new(
            x_axis.x * radius_scale,
            x_axis.y * radius_scale,
            x_axis.z * radius_scale
          )
          scaled_y_axis = Geom::Vector3d.new(
            y_axis.x * radius_scale,
            y_axis.y * radius_scale,
            y_axis.z * radius_scale
          )

          Geom::Transformation.new(
            [
              scaled_x_axis.x, scaled_x_axis.y, scaled_x_axis.z, 0.0,
              scaled_y_axis.x, scaled_y_axis.y, scaled_y_axis.z, 0.0,
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

    end
  end
end
