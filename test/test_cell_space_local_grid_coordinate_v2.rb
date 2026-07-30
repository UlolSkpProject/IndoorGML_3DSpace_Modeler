# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/cell_space_lifecycle_service'
require_relative '../indoor3d/application/indoor_model/local_grid_coordinate_v2'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceLocalGridCoordinateV2Test < Minitest::Test
        FakeCellSpace = Struct.new(:sketchup_group, :storey) do
          def set_storey(value)
            self.storey = value
          end
        end

        def test_v2_context_keeps_scene_order_with_coordinate_preparer
          calls = []
          cell_space = FakeCellSpace.new(:group)
          context = build_context(
            coordinate_preparer: proc { |value| calls << [:coordinate_preparer, value] },
            name_cell_space_entity: proc { |value| calls << [:name_cell_space_entity, value] },
            apply_cell_space_material: proc { |value| calls << [:apply_cell_space_material, value] }
          )

          context.initialize_scene(cell_space, storey: 'F02')

          assert_equal 'F02', cell_space.storey
          assert_equal [
            [:coordinate_preparer, cell_space],
            [:name_cell_space_entity, cell_space],
            [:apply_cell_space_material, cell_space]
          ], calls
        end

        def test_grid_snap_uses_millimeter_tolerance
          host = Object.new
          host.extend(IndoorModel::LocalGridCoordinateV2)

          source_mm = 123.45637
          source_inch = source_mm / IndoorModel::LocalGridCoordinateV2::LOCAL_GRID_V2_MM_PER_INCH
          snapped_inch = host.send(
            :snap_local_grid_v2_value_inch,
            source_inch,
            0.001
          )
          snapped_mm = snapped_inch * IndoorModel::LocalGridCoordinateV2::LOCAL_GRID_V2_MM_PER_INCH

          assert_in_delta 123.456, snapped_mm, 1.0e-9
        end

        def test_grid_snapped_recenter_translation_preserves_grid_membership
          host = Object.new
          host.extend(IndoorModel::LocalGridCoordinateV2)

          vertex_mm = 1000.001
          center_mm = 123.45637
          center_inch = center_mm / IndoorModel::LocalGridCoordinateV2::LOCAL_GRID_V2_MM_PER_INCH
          snapped_center_mm = host.send(
            :snap_local_grid_v2_value_inch,
            center_inch,
            0.001
          ) * IndoorModel::LocalGridCoordinateV2::LOCAL_GRID_V2_MM_PER_INCH

          local_after_mm = vertex_mm - snapped_center_mm
          grid_index = local_after_mm / 0.001

          assert_in_delta grid_index.round, grid_index, 1.0e-8
        end

        private

        def build_context(overrides = {})
          callbacks = {
            coordinate_preparer: proc { |_cell_space| nil },
            ensure_space_features_groups: proc { nil },
            place_cell_group: proc { |group| group },
            default_storey_name: proc { 'F01' },
            fixed_state_height_offset: proc { |_cell_space| nil },
            recenter_cell_space_geometry: proc { |_group, **_options| nil },
            name_cell_space_entity: proc { |_cell_space| nil },
            apply_cell_space_material: proc { |_cell_space| nil },
            track_cell_space_entity: proc { |_group| nil },
            apply_indoor_lock_policy: proc { nil },
            register_cell_space: proc { |_cell_space| true },
            register_state: proc { |_state| nil },
            unregister_cell_space: proc { |_cell_space| nil },
            unregister_state: proc { |_state| nil },
            write_attributes: proc { |_cell_space| nil },
            write_cell_space_attributes: proc { |_cell_space| nil },
            synchronize_adjacency_and_transitions_for_cell_space: proc { |_cell_space| nil },
            erase_transitions_for_state: proc { |_state| nil },
            erase_adjacency_for_cell_space: proc { |_cell_space| nil }
          }.merge(overrides)

          CellSpaceLifecycleLocalGridContextV2.new(**callbacks)
        end
      end
    end
  end
end
