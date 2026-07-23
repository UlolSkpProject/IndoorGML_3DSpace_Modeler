# frozen_string_literal: true

require 'rexml/document'
require 'rexml/formatters/pretty'
require_relative '../definition'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class GmlWriter
          ROOT_ID                    = 'IF_001'
          CORE_NAMESPACE             = "http://www.opengis.net/indoorgml/#{Definition::INDOOR_GML_SCHEMA_VERSION}/core"
          NAVIGATION_NAMESPACE       = "http://www.opengis.net/indoorgml/#{Definition::INDOOR_GML_SCHEMA_VERSION}/navigation"
          CORE_SCHEMA_LOCATION       = "http://schemas.opengis.net/indoorgml/#{Definition::INDOOR_GML_SCHEMA_VERSION}/indoorgmlcore.xsd"
          NAVIGATION_SCHEMA_LOCATION = "http://schemas.opengis.net/indoorgml/#{Definition::INDOOR_GML_SCHEMA_VERSION}/indoorgmlnavi.xsd"
          DEFAULT_STOREY = 'F01'
          CELL_SPACE_TAGS = {
            CellSpaceType::GENERAL => 'navi:GeneralSpace',
            CellSpaceType::TRANSITION => 'navi:TransitionSpace',
            CellSpaceType::CONNECTION => 'navi:ConnectionSpace',
            CellSpaceType::ANCHOR => 'navi:AnchorSpace'
          }.freeze

          def initialize(snapshot:, coordinate_unit:, measure_step: nil)
            @snapshot = snapshot
            @coordinate_unit = coordinate_unit
            @measure_step = measure_step
          end

          def to_xml
            reset_gml_id_mapping
            doc = REXML::Document.new
            doc << REXML::XMLDecl.new('1.0', 'UTF-8')
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
            measure('append primalSpaceFeatures') { append_primal_space_features(root) }
            measure('append multiLayeredGraph') { append_multi_layered_graph(root) }
            measure('format XML') { pretty_xml(doc) }
          end

          def self.cell_space_tag(cell_space)
            CELL_SPACE_TAGS[cell_space.cell_type] || 'core:CellSpace'
          end

          private

          def measure(label)
            return yield unless @measure_step

            @measure_step.call(label) { yield }
          end

          def append_primal_space_features(root)
            primal_space_features = root.add_element('core:primalSpaceFeatures')
            primal = primal_space_features.add_element('core:PrimalSpaceFeatures')
            primal.add_attribute('gml:id', 'PS1')
            @snapshot.cell_spaces.each do |cell_space|
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
            tag = self.class.cell_space_tag(cell_space)
            cell = member.add_element(tag)
            cell.add_attribute('gml:id', cell_id)
            cell.add_element('gml:description').text = cell_space_description(cell_space)
            cell.add_element('gml:name').text = cell_space_export_name(cell_space)
            append_nil_bounded_by(cell)
            geometry = cell.add_element('core:cellSpaceGeometry')
            geometry_3d = geometry.add_element('core:Geometry3D')
            solid = geometry_3d.add_element('gml:Solid')
            solid.add_attribute('gml:id', "solid_#{cell_id}")
            append_local_crs_attributes(solid)
            exterior = solid.add_element('gml:exterior')
            shell = exterior.add_element('gml:Shell')
            shell.add_attribute('gml:id', "shell_#{cell_id}")
            append_cell_surfaces(shell, cell_space, cell_id)
            duality = cell.add_element('core:duality')
            duality.add_attribute('xlink:href', internal_href(state_gml_id(cell_space.duality_state)))
            append_navigable_space_codes(cell, cell_space) if tag.start_with?('navi:')
          end

          def append_states(space_layer)
            nodes = space_layer.add_element('core:nodes')
            nodes.add_attribute('gml:id', 'N1')
            @snapshot.cell_spaces.each_with_index do |cell_space, index|
              state = cell_space.duality_state
              member = nodes.add_element('core:stateMember')
              state_element = member.add_element('core:State')
              state_element.add_attribute('gml:id', state_gml_id(state))
              state_element.add_element('gml:description').text = state_description(state)
              state_element.add_element('gml:name').text = state_export_name(state)
              duality = state_element.add_element('core:duality')
              duality.add_attribute('xlink:href', internal_href(cell_gml_id(cell_space)))
              transitions_for_state(state).each do |transition|
                connects = state_element.add_element('core:connects')
                connects.add_attribute('xlink:href', internal_href(transition_gml_id(transition)))
              end
              geometry = state_element.add_element('core:geometry')
              point = geometry.add_element('gml:Point')
              point.add_attribute('gml:id', "P#{index}")
              append_local_crs_attributes(point)
              point.add_element('gml:pos').text = format_point(state.position)
            end
          end

          def append_transitions(space_layer)
            edges = space_layer.add_element('core:edges')
            edges.add_attribute('gml:id', 'E1')
            @snapshot.transitions.each do |transition|
              member = edges.add_element('core:transitionMember')
              transition_element = member.add_element('core:Transition')
              transition_element.add_attribute('gml:id', transition_gml_id(transition))
              transition_element.add_element('core:weight').text = '1'
              connects1 = transition_element.add_element('core:connects')
              connects1.add_attribute('xlink:href', internal_href(state_gml_id(transition.state1)))
              connects2 = transition_element.add_element('core:connects')
              connects2.add_attribute('xlink:href', internal_href(state_gml_id(transition.state2)))
              geometry = transition_element.add_element('core:geometry')
              line = geometry.add_element('gml:LineString')
              line.add_attribute('gml:id', "line_#{transition_gml_id(transition)}")
              append_local_crs_attributes(line)
              line.add_element('gml:pos').text = format_point(transition.state1_position)
              line.add_element('gml:pos').text = format_point(transition.state2_position)
            end
          end

          def append_cell_surfaces(shell, cell_space, cell_id)
            Array(cell_space.surfaces).each_with_index do |surface, index|
              surface_member = shell.add_element('gml:surfaceMember')
              polygon = surface_member.add_element('gml:Polygon')
              polygon.add_attribute('gml:id', "polygon_#{surface.id_hint || index}_#{cell_id}")
              append_local_crs_attributes(polygon)
              append_ring(polygon.add_element('gml:exterior'), surface.exterior)
              Array(surface.interiors).each do |ring|
                append_ring(polygon.add_element('gml:interior'), ring)
              end
            end
          end

          def append_ring(parent, points)
            linear_ring = parent.add_element('gml:LinearRing')
            Array(points).each do |point|
              linear_ring.add_element('gml:pos').text = format_point(point)
            end
          end

          def append_local_crs_attributes(element)
            unit = @coordinate_unit
            element.add_attribute('srsName', unit[:srs_name])
            element.add_attribute('srsDimension', '3')
            element.add_attribute('axisLabels', 'x y z')
            element.add_attribute('uomLabels', "#{unit[:unit]} #{unit[:unit]} #{unit[:unit]}")
          end

          def format_point(point)
            [
              format_number(export_coordinate_value(point.x)),
              format_number(export_coordinate_value(point.y)),
              format_number(export_coordinate_value(point.z))
            ].join(' ')
          end

          def export_coordinate_value(value)
            value.to_f * @coordinate_unit[:factor]
          end

          def format_number(value)
            numeric = value.to_f
            return '0' if numeric.abs < 1.0e-15

            format('%.17g', numeric)
          end

          def cell_gml_id(cell_space)
            mapped_feature_gml_id(:cell, cell_space, 'cell')
          end

          def state_gml_id(state)
            mapped_feature_gml_id(:state, state, 'state')
          end

          def transition_gml_id(transition)
            mapped_feature_gml_id(:transition, transition, 'transition')
          end

          def internal_href(gml_id)
            "##{gml_id}"
          end

          def safe_id(value)
            value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
          end

          def reset_gml_id_mapping
            @feature_gml_ids = {}
            @used_feature_gml_ids = {}
          end

          def mapped_feature_gml_id(kind, feature, prefix)
            key = [kind, feature&.object_id]
            return @feature_gml_ids[key] if @feature_gml_ids.key?(key)

            normalized = safe_id(feature&.id)
            normalized = 'missing' if normalized.empty?
            base = "#{prefix}_#{normalized}"
            candidate = base
            suffix = 2
            while @used_feature_gml_ids[candidate]
              candidate = "#{base}_#{suffix}"
              suffix += 1
            end
            @used_feature_gml_ids[candidate] = true
            @feature_gml_ids[key] = candidate
          end

          def transitions_for_state(state)
            Array(@snapshot.transitions).select do |transition|
              transition.state1.equal?(state) || transition.state2.equal?(state)
            end
          end

          def cell_space_export_name(cell_space)
            "Cell-#{safe_id(cell_space.id)}"
          end

          def state_export_name(state)
            "State-#{safe_id(state.id)}"
          end

          def cell_space_description(cell_space)
            "storey=#{storey_name_for(cell_space)}"
          end

          def state_description(state)
            "storey=#{storey_name_for(state&.duality_cell)}"
          end

          def storey_name_for(cell_space)
            storey = cell_space&.storey.to_s
            storey.empty? ? DEFAULT_STOREY : storey
          end

          def append_nil_bounded_by(parent)
            bounded_by = parent.add_element('gml:boundedBy')
            bounded_by.add_attribute('xsi:nil', 'true')
          end

          def append_navigable_space_codes(cell, cell_space)
            semantic = NavigationSemanticResolver.resolve(cell_space)
            append_code(cell, 'navi:class', semantic.class_value, semantic.class_code_space)
            append_code(cell, 'navi:function', semantic.function_value, semantic.function_code_space)
            append_code(cell, 'navi:usage', semantic.usage_value, semantic.usage_code_space)
          end

          def append_code(parent, tag, value, code_space)
            return if value.to_s.empty?

            element = parent.add_element(tag)
            element.add_attribute('codeSpace', code_space) unless code_space.to_s.empty?
            element.text = value.to_s
          end

        end
      end
    end
  end
end
