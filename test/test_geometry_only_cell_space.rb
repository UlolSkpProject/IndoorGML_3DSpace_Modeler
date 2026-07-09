# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Group; end unless const_defined?(:Group, false)
  class ComponentInstance; end unless const_defined?(:ComponentInstance, false)
end

require_relative '../indoor3d/domain/abstract_feature'
require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/domain/cell_space_category'
require_relative '../indoor3d/domain/navigation_semantic'
require_relative '../indoor3d/domain/cell_space'
require_relative '../indoor3d/application/indoor_model/topology'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class GeometryOnlyCellSpaceTest < Minitest::Test
        def test_cell_space_type_policy
          assert_equal 'CellSpace', CellSpaceType.label(CellSpaceType::GEOMETRY_ONLY)
          assert_includes CellSpaceType::SELECTABLE_TYPES, CellSpaceType::GEOMETRY_ONLY
          refute_includes CellSpaceType::NAVIGABLE_TYPES, CellSpaceType::GEOMETRY_ONLY
          refute CellSpaceType.navigable?(CellSpaceType::GEOMETRY_ONLY)
          assert CellSpaceType.geometry_only?(CellSpaceType::GEOMETRY_ONLY)
        end

        def test_cell_space_category_window_default_and_selection
          category = CellSpaceCategory.default_for(CellSpaceType::GEOMETRY_ONLY)

          assert_equal 'Window', category[:code]
          assert_equal 'Window', category[:label]
          assert_nil category[:code_space]
          assert_equal false, category[:standard]

          labels = CellSpaceCategory.selection_options.map { |option| option[:label] }
          assert_includes labels, 'Window : CellSpace'

          cell_type, category_code = CellSpaceCategory.parse_selection_value('CellSpace|Window')
          assert_equal CellSpaceType::GEOMETRY_ONLY, cell_type
          assert_equal 'Window', category_code
        end

        def test_geometry_only_cell_space_clears_navigation_semantics
          cell_space = CellSpace.new(FakeGroup.new, CellSpaceType::GEOMETRY_ONLY, 'Window')

          assert cell_space.geometry_only?
          refute cell_space.navigable?
          assert_equal 'Window', cell_space.category_code
          assert_nil cell_space.navigation_class
          assert_nil cell_space.navigation_class_code_space
          assert_nil cell_space.navigation_function
          assert_nil cell_space.navigation_function_code_space
          assert_nil cell_space.navigation_usage
          assert_nil cell_space.navigation_usage_code_space
        end

        def test_transition_creation_skips_geometry_only_cells_in_persistent_and_runtime_paths
          model = FakeTopologyModel.new
          general = FakeCell.new('room', navigable: true)
          geometry_only = FakeCell.new('window', navigable: false)

          assert_nil model.create_persistent_transition(general, geometry_only)
          assert_nil model.create_runtime_transition(geometry_only, general)
          assert_equal 0, model.registry_queries
        end

        private

        class FakeGroup < Sketchup::Group
          def valid?
            true
          end

          def manifold?
            true
          end

          def persistent_id
            1
          end
        end

        class FakeState
          def valid?
            true
          end
        end

        class FakeCell
          attr_reader :id, :duality_state

          def initialize(id, navigable:)
            @id = id
            @navigable = navigable
            @duality_state = FakeState.new
          end

          def valid?
            true
          end

          def navigable?
            @navigable == true
          end
        end

        class FakeTopologyModel
          include IndoorModel::Topology

          attr_reader :registry_queries

          def initialize
            @registry_queries = 0
            @feature_registry = self
          end

          def create_persistent_transition(cell1, cell2)
            send(:create_or_update_transition_for_pair, cell1, cell2)
          end

          def create_runtime_transition(cell1, cell2)
            send(:create_or_update_runtime_transition_for_pair, cell1, cell2)
          end

          def transition_for_pair(_pair_key)
            @registry_queries += 1
            nil
          end
        end
      end
    end
  end
end
