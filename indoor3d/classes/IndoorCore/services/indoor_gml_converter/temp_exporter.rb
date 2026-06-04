# frozen_string_literal: true

require 'fileutils'
require 'rexml/document'
require 'rexml/formatters/pretty'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class TempExporter
          ROOT_ID = 'IF_001'
          COORDINATE_SYSTEM_Z_UP_RH = :z_up_rh
          COORDINATE_SYSTEM_Y_UP_LH = :y_up_lh
          CORE_NAMESPACE = 'http://www.opengis.net/indoorgml/1.0/core'
          NAVIGATION_NAMESPACE = 'http://www.opengis.net/indoorgml/1.0/navigation'
          CORE_SCHEMA_LOCATION = 'http://schemas.opengis.net/indoorgml/1.0/indoorgmlcore.xsd'
          NAVIGATION_SCHEMA_LOCATION = 'http://schemas.opengis.net/indoorgml/1.0/indoorgmlnavi.xsd'
          CELL_SPACE_TAGS = {
            CellSpaceType::GENERAL => 'navi:GeneralSpace',
            CellSpaceType::TRANSITION => 'navi:TransitionSpace',
            CellSpaceType::CONNECTION => 'navi:ConnectionSpace',
            CellSpaceType::ANCHOR => 'navi:AnchorSpace'
          }.freeze

          def initialize(indoor_model, refresh_runtime_data: true, coordinate_system: COORDINATE_SYSTEM_Z_UP_RH)
            @indoor_model = indoor_model
            @refresh_runtime_data = refresh_runtime_data
            @coordinate_system = coordinate_system
          end

          def export(output_path: self.class.default_temp_gml_path)
            @indoor_model.refresh_runtime_data if @refresh_runtime_data
            output_path = File.expand_path(output_path)
            FileUtils.mkdir_p(File.dirname(output_path))
            File.write(output_path, document)
            output_path
          end

          def self.output_root
            File.expand_path('../../../../tmp/indoorgml', __dir__)
          end

          def self.default_temp_gml_path
            File.join(output_root, 'temp.gml')
          end

          private

          def document
            doc = REXML::Document.new
            doc << REXML::XMLDecl.new('1.0', "UTF-8")
            root = doc.add_element('core:IndoorFeatures')
            root.add_namespace(CORE_NAMESPACE)
            root.add_namespace('core', CORE_NAMESPACE)
            root.add_namespace('navi', NAVIGATION_NAMESPACE)
            root.add_namespace('gml', 'http://www.opengis.net/gml/3.2')
            root.add_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
            root.add_namespace('xlink', 'http://www.w3.org/1999/xlink')
            root.add_attribute(
              'xsi:schemaLocation',
              "#{CORE_NAMESPACE} #{CORE_SCHEMA_LOCATION} #{NAVIGATION_NAMESPACE} #{NAVIGATION_SCHEMA_LOCATION}"
            )
            root.add_attribute('gml:id', ROOT_ID)
            append_nil_bounded_by(root)
            append_primal_space_features(root)
            append_multi_layered_graph(root)
            pretty_xml(doc)
          end

          def append_primal_space_features(root)
            primal_space_features = root.add_element('core:primalSpaceFeatures')
            primal = primal_space_features.add_element('core:PrimalSpaceFeatures')
            primal.add_attribute('gml:id', 'PS1')
            exportable_cell_spaces.each do |cell_space|
              append_cell_space(primal, cell_space)
            end
          end

          def append_multi_layered_graph(root)
            graph_property = root.add_element('core:multiLayeredGraph')
            graph = graph_property.add_element('core:MultiLayeredGraph')
            graph.add_attribute('gml:id', 'MG1')
            space_layers = graph.add_element('core:spaceLayers')
            space_layers.add_attribute('gml:id', 'SL1')
            member = space_layers.add_element('core:spaceLayerMember')
            space_layer = member.add_element('core:SpaceLayer')
            space_layer.add_attribute('gml:id', 'IS1')
            append_states(space_layer)
            append_transitions(space_layer)
          end

          def pretty_xml(doc)
            output = +''
            formatter = REXML::Formatters::Pretty.new(2)
            formatter.compact = true
            formatter.write(doc, output)
            output
          end

          def append_cell_space(parent, cell_space)
            cell_id = cell_gml_id(cell_space)
            member = parent.add_element('core:cellSpaceMember')
            cell = member.add_element(cell_space_tag(cell_space))
            cell.add_attribute('gml:id', cell_id)
            cell.add_element('gml:description').text = cell_space_description(cell_space)
            cell.add_element('gml:name').text = cell_space_export_name(cell_space)
            append_nil_bounded_by(cell)
            geometry = cell.add_element('core:cellSpaceGeometry')
            geometry_3d = geometry.add_element('core:Geometry3D')
            solid = geometry_3d.add_element('gml:Solid')
            solid.add_attribute('gml:id', "solid_#{cell_id}")
            exterior = solid.add_element('gml:exterior')
            shell = exterior.add_element('gml:Shell')
            shell.add_attribute('gml:id', "shell_#{cell_id}")
            append_cell_surfaces(shell, cell_space, cell_id)
            duality = cell.add_element('core:duality')
            duality.add_attribute('xlink:href', state_gml_id(cell_space.duality_state))
            append_navigable_space_codes(cell, cell_space)
          end

          def append_cell_surfaces(shell, cell_space, cell_id)
            group = cell_space.valid_sketchup_group
            return unless group

            world_transform = Utils::Transformation.entity_world_transformation(group)
            solid_center = export_point(group.definition.bounds.center.transform(world_transform))
            faces = group.definition.entities.grep(Sketchup::Face)
            faces.each_with_index do |face, index|
              surface_member = shell.add_element('gml:surfaceMember')
              polygon = surface_member.add_element('gml:Polygon')
              polygon.add_attribute('gml:id', "polygon_#{index}_#{cell_id}")
              exterior = polygon.add_element('gml:exterior')
              linear_ring = exterior.add_element('gml:LinearRing')
              convert_ring_winding(ring_points(face, world_transform), solid_center).each do |point|
                linear_ring.add_element('gml:pos').text = format_export_point(point)
              end
            end
          end

          def append_states(space_layer)
            nodes = space_layer.add_element('core:nodes')
            nodes.add_attribute('gml:id', 'N1')
            exportable_cell_spaces.each_with_index do |cell_space, index|
              state = cell_space.duality_state
              member = nodes.add_element('core:stateMember')
              state_element = member.add_element('core:State')
              state_element.add_attribute('gml:id', state_gml_id(state))
              state_element.add_element('gml:name').text = state_export_name(state)
              duality = state_element.add_element('core:duality')
              duality.add_attribute('xlink:href', cell_gml_id(cell_space))
              state_connected_transition_ids(state).each do |transition_id|
                connects = state_element.add_element('core:connects')
                connects.add_attribute('xlink:href', transition_id)
              end
              geometry = state_element.add_element('core:geometry')
              point = geometry.add_element('gml:Point')
              point.add_attribute('gml:id', "P#{index}")
              point.add_element('gml:pos').text = format_point(state_world_position(state))
            end
          end

          def append_transitions(space_layer)
            edges = space_layer.add_element('core:edges')
            edges.add_attribute('gml:id', 'E1')
            exportable_transitions.each do |transition|
              member = edges.add_element('core:transitionMember')
              transition_element = member.add_element('core:Transition')
              transition_element.add_attribute('gml:id', transition_gml_id(transition))
              connects1 = transition_element.add_element('core:connects')
              connects1.add_attribute('xlink:href', state_gml_id(transition.state1))
              connects2 = transition_element.add_element('core:connects')
              connects2.add_attribute('xlink:href', state_gml_id(transition.state2))
              geometry = transition_element.add_element('core:geometry')
              line = geometry.add_element('gml:LineString')
              line.add_attribute('gml:id', "line_#{transition_gml_id(transition)}")
              line.add_element('gml:pos').text = format_point(state_world_position(transition.state1))
              line.add_element('gml:pos').text = format_point(state_world_position(transition.state2))
            end
          end

          def exportable_cell_spaces
            @exportable_cell_spaces ||= @indoor_model.cell_spaces.select do |cell_space|
              cell_space&.valid_sketchup_group && cell_space.duality_state&.valid?
            end
          end

          def exportable_transitions
            @indoor_model.transitions.select do |transition|
              transition&.valid? &&
                transition.state1&.valid? &&
                transition.state2&.valid? &&
                exportable_cell_spaces.include?(transition.state1.duality_cell) &&
                exportable_cell_spaces.include?(transition.state2.duality_cell)
            end
          end

          def ring_points(face, transform)
            face.outer_loop.vertices.map do |vertex|
              export_point(vertex.position.transform(transform))
            end
          end

          def convert_ring_winding(points, solid_center)
            points = points.dup
            points.reverse! unless outward_ring?(points, solid_center)
            points << points.first if points.first
            points
          end

          def outward_ring?(points, solid_center)
            normal = polygon_normal(points)
            return true if normal.nil? || normal.length <= 0.000001

            center = average_point(points)
            direction = solid_center.vector_to(center)
            return true if direction.length <= 0.000001

            normal.dot(direction) > 0.0
          end

          def polygon_normal(points)
            return nil if points.length < 3

            x = 0.0
            y = 0.0
            z = 0.0
            points.each_with_index do |point, index|
              next_point = points[(index + 1) % points.length]
              x += (point.y - next_point.y) * (point.z + next_point.z)
              y += (point.z - next_point.z) * (point.x + next_point.x)
              z += (point.x - next_point.x) * (point.y + next_point.y)
            end
            normal = Geom::Vector3d.new(x, y, z)
            normal.length <= 0.000001 ? nil : normal
          end

          def average_point(points)
            x = points.map(&:x).sum / points.length.to_f
            y = points.map(&:y).sum / points.length.to_f
            z = points.map(&:z).sum / points.length.to_f
            Geom::Point3d.new(x, y, z)
          end

          def state_world_position(state)
            point = state.position
            primal_group = @indoor_model.primal_group
            return point unless primal_group&.valid?

            point.transform(primal_group.transformation)
          end

          def format_point(point)
            format_export_point(export_point(point))
          end

          def format_export_point(point)
            [format_number(point.x), format_number(point.y), format_number(point.z)].join(' ')
          end

          def export_point(point)
            if @coordinate_system == COORDINATE_SYSTEM_Y_UP_LH
              Geom::Point3d.new(point.x, point.z, -point.y)
            else
              Geom::Point3d.new(point.x, point.y, point.z)
            end
          end

          def format_number(value)
            numeric = value.to_f
            return numeric.round.to_s if (numeric - numeric.round).abs < 0.000001

            format('%.6f', numeric).sub(/0+\z/, '').sub(/\.\z/, '')
          end

          def cell_gml_id(cell_space)
            "cell_#{safe_id(cell_space.id)}"
          end

          def state_gml_id(state)
            "state_#{safe_id(state.id)}"
          end

          def transition_gml_id(transition)
            "transition_#{safe_id(transition.id)}"
          end

          def safe_id(value)
            value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
          end

          def cell_space_tag(cell_space)
            CELL_SPACE_TAGS[cell_space.cell_type] || 'core:CellSpace'
          end

          def cell_space_export_name(cell_space)
            "Cell-#{safe_id(cell_space.id)}"
          end

          def state_export_name(state)
            "State-#{safe_id(state.id)}"
          end

          def cell_space_description(cell_space)
            %(storey="floor_1":indoor=#{indoor_description_type(cell_space)})
          end

          def indoor_description_type(cell_space)
            category = cell_space.category_code.to_s.downcase
            return 'room' if category.include?('room')
            return 'door' if category.include?('door')
            return 'stairs' if category.include?('stair')
            return 'elevator' if category.include?('elevator')
            return 'corridor' if category.include?('corridor')
            return 'entrance' if category.include?('entrance') || category.include?('enterance')

            case cell_space.cell_type
            when CellSpaceType::GENERAL
              'room'
            when CellSpaceType::CONNECTION
              'door'
            when CellSpaceType::TRANSITION
              'transition'
            when CellSpaceType::ANCHOR
              'entrance'
            else
              'space'
            end
          end

          def append_nil_bounded_by(parent)
            bounded_by = parent.add_element('gml:boundedBy')
            bounded_by.add_attribute('xsi:nil', 'true')
          end

          def append_navigable_space_codes(cell, cell_space)
            append_code(cell, 'navi:class', CellSpaceType.label(cell_space.cell_type), cell_space.category_code_space)
            append_code(cell, 'navi:function', cell_space.category_code, cell_space.category_code_space)
            append_code(cell, 'navi:usage', cell_space.category_code, cell_space.category_code_space)
          end

          def append_code(parent, tag, value, code_space)
            element = parent.add_element(tag)
            element.add_attribute('codeSpace', code_space) unless code_space.to_s.empty?
            element.text = value.to_s
          end

          def state_connected_transition_ids(state)
            exportable_transitions.filter_map do |transition|
              next unless transition.state1 == state || transition.state2 == state

              transition_gml_id(transition)
            end
          end
        end

      end
    end
  end
end
