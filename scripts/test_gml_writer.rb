# frozen_string_literal: true

require 'minitest/autorun'
require 'rexml/document'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceType
        GENERAL = :general
        TRANSITION = :transition
        CONNECTION = :connection
        ANCHOR = :anchor
      end unless const_defined?(:CellSpaceType)

      class Storey
        DEFAULT_NAME = 'F01'
      end unless const_defined?(:Storey)

      class NavigationSemanticResolver
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
          def test_writer_builds_core_xml_with_geometry_callback_and_graph
            state = fake_state('S 1')
            cell = fake_cell_space('Cell A', :unknown, 'B02', state)
            state.duality_cell = cell
            snapshot = ExportSnapshot.new(cell_spaces: [cell], transitions: [])
            geometry_calls = []
            writer = GmlWriter.new(
              snapshot: snapshot,
              coordinate_unit: { unit: 'm', factor: 0.0254, srs_name: 'urn:test:m' },
              geometry_appender: proc { |shell, cell_space, cell_id| geometry_calls << [shell.name, cell_space, cell_id] },
              state_position: proc { |_state| fake_point(1.0, 2.0, 3.0) },
              transition_state1_position: proc { |_transition| fake_point(0.0, 0.0, 0.0) },
              transition_state2_position: proc { |_transition| fake_point(0.0, 0.0, 0.0) }
            )

            xml = writer.to_xml
            doc = REXML::Document.new(xml)

            assert_equal 'IndoorFeatures', doc.root.name
            assert_equal 'IF_001', doc.root.attributes['gml:id']
            assert_equal [['Shell', cell, 'cell_Cell_A']], geometry_calls
            assert_xpath(doc, '//core:CellSpace[@gml:id="cell_Cell_A"]')
            assert_xpath(doc, '//core:State[@gml:id="state_S_1"]')
            assert_xpath(doc, '//gml:Point[@srsName="urn:test:m"]')
            assert_includes xml, '0.025399999999999999 0.050799999999999998 0.07619999999999999'
          end

          def test_writer_builds_navigable_codes_and_transition_links
            state1 = fake_state('S1')
            state2 = fake_state('S2')
            cell1 = fake_cell_space('A', CellSpaceType::GENERAL, nil, state1)
            cell2 = fake_cell_space('B', CellSpaceType::GENERAL, nil, state2)
            state1.duality_cell = cell1
            state2.duality_cell = cell2
            transition = fake_transition('T 1', state1, state2)
            snapshot = ExportSnapshot.new(cell_spaces: [cell1, cell2], transitions: [transition])
            writer = GmlWriter.new(
              snapshot: snapshot,
              coordinate_unit: { unit: 'in', factor: 1.0, srs_name: 'urn:test:in' },
              geometry_appender: proc { |_shell, _cell_space, _cell_id| nil },
              state_position: proc { |_state| fake_point(0, 0, 0) },
              transition_state1_position: proc { |_transition| fake_point(1, 0, 0) },
              transition_state2_position: proc { |_transition| fake_point(2, 0, 0) }
            )

            xml = writer.to_xml
            doc = REXML::Document.new(xml)

            assert_xpath(doc, '//navi:GeneralSpace[@gml:id="cell_A"]')
            assert_xpath(doc, '//navi:class')
            assert_xpath(doc, '//core:Transition[@gml:id="transition_T_1"]')
            assert_includes xml, "xlink:href='#transition_T_1'"
          end

          private

          def assert_xpath(doc, xpath)
            refute_nil REXML::XPath.first(doc, xpath, namespaces)
          end

          def namespaces
            {
              'core' => GmlWriter::CORE_NAMESPACE,
              'navi' => GmlWriter::NAVIGATION_NAMESPACE,
              'gml' => 'http://www.opengis.net/gml/3.2'
            }
          end

          def fake_cell_space(id, cell_type, storey, state)
            Struct.new(:id, :cell_type, :storey, :duality_state).new(id, cell_type, storey, state)
          end

          def fake_state(id)
            Struct.new(:id, :duality_cell, keyword_init: true).new(id: id, duality_cell: nil)
          end

          def fake_transition(id, state1, state2)
            Struct.new(:id, :state1, :state2).new(id, state1, state2)
          end

          def fake_point(x, y, z)
            Struct.new(:x, :y, :z).new(x, y, z)
          end
        end
      end
    end
  end
end
