# frozen_string_literal: true

require 'minitest/autorun'
require 'rexml/document'

require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/domain/cell_space_category'
require_relative '../indoor3d/domain/navigation_semantic'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceType
        GENERAL = :general
        TRANSITION = :transition
        CONNECTION = :connection
        ANCHOR = :anchor
      end unless const_defined?(:CellSpaceType)

      module NavigationSemanticResolver
        Semantic = Struct.new(:class_value, :class_code_space, :function_value, :function_code_space, :usage_value, :usage_code_space)

        def self.resolve(_cell_space)
          Semantic.new('1000', 'classSpace', 'room', 'functionSpace', 'room', 'usageSpace')
        end
      end unless const_defined?(:NavigationSemanticResolver)
    end
  end
end

require_relative '../indoor3d/export/gml_writer'
require_relative '../indoor3d/export/export_snapshot'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class GmlWriterTest < Minitest::Test
          def test_writer_uses_official_schema_version_for_namespaces
            assert_includes GmlWriter::CORE_NAMESPACE, "/#{Definition::INDOOR_GML_SCHEMA_VERSION}/core"
            assert_includes GmlWriter::NAVIGATION_NAMESPACE, "/#{Definition::INDOOR_GML_SCHEMA_VERSION}/navigation"
            assert_includes GmlWriter::CORE_SCHEMA_LOCATION, "/#{Definition::INDOOR_GML_SCHEMA_VERSION}/indoorgmlcore.xsd"
            assert_includes GmlWriter::NAVIGATION_SCHEMA_LOCATION, "/#{Definition::INDOOR_GML_SCHEMA_VERSION}/indoorgmlnavi.xsd"
            refute_includes GmlWriter::CORE_SCHEMA_LOCATION, "/#{Definition::INDOOR_GML_VERSION}/"
            refute_includes GmlWriter::NAVIGATION_SCHEMA_LOCATION, "/#{Definition::INDOOR_GML_VERSION}/"
          end

          def test_writer_builds_core_xml_with_snapshot_geometry_and_graph
            state = fake_state('S 1')
            cell = fake_cell_space('Cell A', :unknown, 'B02', state, surfaces: [fake_surface])
            state.duality_cell = cell
            snapshot = ExportSnapshot.new(cell_spaces: [cell], transitions: [])
            writer = GmlWriter.new(
              snapshot: snapshot,
              coordinate_unit: { unit: 'm', factor: 0.0254, srs_name: 'urn:test:m' }
            )

            xml = writer.to_xml
            doc = REXML::Document.new(xml)

            assert_equal 'IndoorFeatures', doc.root.name
            assert_equal 'IF_001', doc.root.attributes['gml:id']
            assert_xpath(doc, '//core:CellSpace[@gml:id="cell_Cell_A"]')
            assert_xpath(doc, '//core:State[@gml:id="state_S_1"]')
            assert_xpath(doc, '//gml:Polygon[@gml:id="polygon_0_cell_Cell_A"]')
            assert_xpath(doc, '//gml:Point[@srsName="urn:test:m"]')
            assert_includes xml, '0.025399999999999999 0.050799999999999998 0.07619999999999999'
          end

          def test_writer_builds_navigable_codes_and_transition_links
            state1 = fake_state('S1', transition_ids: ['T 1'])
            state2 = fake_state('S2', transition_ids: ['T 1'])
            cell1 = fake_cell_space('A', CellSpaceType::GENERAL, nil, state1)
            cell2 = fake_cell_space('B', CellSpaceType::GENERAL, nil, state2)
            state1.duality_cell = cell1
            state2.duality_cell = cell2
            transition = fake_transition('T 1', state1, state2, fake_point(1, 0, 0), fake_point(2, 0, 0))
            snapshot = ExportSnapshot.new(cell_spaces: [cell1, cell2], transitions: [transition])
            writer = GmlWriter.new(
              snapshot: snapshot,
              coordinate_unit: { unit: 'in', factor: 1.0, srs_name: 'urn:test:in' }
            )

            xml = writer.to_xml
            doc = REXML::Document.new(xml)

            assert_xpath(doc, '//navi:GeneralSpace[@gml:id="cell_A"]')
            assert_xpath(doc, '//navi:class')
            assert_xpath(doc, '//core:Transition[@gml:id="transition_T_1"]')
            assert_includes xml, "xlink:href='#transition_T_1'"
          end

          def test_writer_uses_state_snapshot_transition_ids_for_state_connects
            state1 = fake_state('S1', transition_ids: ['Raw T'])
            state2 = fake_state('S2')
            cell1 = fake_cell_space('A', CellSpaceType::GENERAL, nil, state1)
            cell2 = fake_cell_space('B', CellSpaceType::GENERAL, nil, state2)
            state1.duality_cell = cell1
            state2.duality_cell = cell2
            transition = fake_transition('Raw T', state1, state2, fake_point(1, 0, 0), fake_point(2, 0, 0))
            snapshot = ExportSnapshot.new(cell_spaces: [cell1, cell2], transitions: [transition])
            writer = GmlWriter.new(
              snapshot: snapshot,
              coordinate_unit: { unit: 'in', factor: 1.0, srs_name: 'urn:test:in' }
            )

            xml = writer.to_xml

            assert_includes xml, "xlink:href='#transition_Raw_T'"
          end

          def test_writer_exports_geometry_only_cell_space_as_core_cell_space_without_navi_codes
            state = fake_state('Window State')
            cell = fake_cell_space('Window', CellSpaceType::GEOMETRY_ONLY, 'F01', state, surfaces: [fake_surface], category_code: 'Window')
            state.duality_cell = cell
            snapshot = ExportSnapshot.new(cell_spaces: [cell], transitions: [])
            writer = GmlWriter.new(
              snapshot: snapshot,
              coordinate_unit: { unit: 'in', factor: 1.0, srs_name: 'urn:test:in' }
            )

            xml = writer.to_xml
            doc = REXML::Document.new(xml)

            assert_xpath(doc, '//core:CellSpace[@gml:id="cell_Window"]')
            refute_xpath(doc, '//navi:GeneralSpace[@gml:id="cell_Window"]')
            refute_xpath(doc, '//navi:class')
            refute_xpath(doc, '//navi:function')
            refute_xpath(doc, '//navi:usage')
            assert_xpath(doc, '//core:CellSpace[@gml:id="cell_Window"]/core:duality')
            assert_xpath(doc, '//core:State[@gml:id="state_Window_State"]')
            refute_includes GmlWriter::CELL_SPACE_TAGS.keys, CellSpaceType::GEOMETRY_ONLY
          end

          private

          def assert_xpath(doc, xpath)
            refute_nil REXML::XPath.first(doc, xpath, namespaces)
          end

          def refute_xpath(doc, xpath)
            assert_nil REXML::XPath.first(doc, xpath, namespaces)
          end

          def namespaces
            {
              'core' => GmlWriter::CORE_NAMESPACE,
              'navi' => GmlWriter::NAVIGATION_NAMESPACE,
              'gml' => 'http://www.opengis.net/gml/3.2'
            }
          end

          def fake_cell_space(id, cell_type, storey, state, surfaces: [], category_code: 'Room')
            ExportSnapshot::CellSpaceSnapshot.new(
              id: id,
              cell_type: cell_type,
              storey: storey,
              duality_state: state,
              surfaces: surfaces,
              category_code: category_code
            )
          end

          def fake_state(id, transition_ids: [])
            ExportSnapshot::StateSnapshot.new(
              id: id,
              duality_cell: nil,
              position: fake_point(1.0, 2.0, 3.0),
              transition_ids: transition_ids
            )
          end

          def fake_transition(id, state1, state2, state1_position, state2_position)
            ExportSnapshot::TransitionSnapshot.new(
              id: id,
              state1: state1,
              state2: state2,
              state1_position: state1_position,
              state2_position: state2_position
            )
          end

          def fake_surface
            ExportSnapshot::SurfaceSnapshot.new(
              id_hint: 0,
              exterior: [
                fake_point(0, 0, 0),
                fake_point(1, 0, 0),
                fake_point(0, 1, 0),
                fake_point(0, 0, 0)
              ],
              interiors: []
            )
          end

          def fake_point(x, y, z)
            Struct.new(:x, :y, :z).new(x, y, z)
          end
        end
      end
    end
  end
end
