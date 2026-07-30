# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/feature_registry'
require_relative '../indoor3d/application/cell_space_lifecycle_service'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # The production Local Grid V2 context is loaded by IndoorModel before the
      # batch module. This lightweight definition keeps this unit test focused on
      # lifecycle responsibility boundaries without loading SketchUp geometry code.
      class CellSpaceLifecycleLocalGridContextV2 < CellSpaceLifecycleContext
        def initialize(coordinate_preparer:, **callbacks)
          @coordinate_preparer = coordinate_preparer
          super(**callbacks)
        end
      end unless const_defined?(:CellSpaceLifecycleLocalGridContextV2, false)

      class IndoorModel; end unless const_defined?(:IndoorModel, false)
    end
  end
end

require_relative '../indoor3d/application/indoor_model/cell_space_batch_lifecycle'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceBatchLifecycleTest < Minitest::Test
        FakeGroup = Struct.new(:persistent_id, :entityID)
        FakeFeature = Struct.new(:id, :sketchup_group)
        FakeState = Struct.new(:id)

        class FakeCellSpace
          attr_reader :sketchup_group
          attr_reader :storey

          def initialize(group)
            @sketchup_group = group
          end

          def set_storey(storey)
            @storey = storey
          end
        end

        def test_batch_context_keeps_cross_cutting_work_out_of_single_create
          calls = []
          group = Object.new
          state = Object.new
          cell_space = FakeCellSpace.new(group)
          context = CellSpaceBatchLifecycleContext.new(
            **callbacks(calls, placed_group: group)
          )

          assert_same group, context.prepare_cell_group(Object.new)
          context.initialize_scene(cell_space, storey: 'F02')
          context.register_created(
            cell_space,
            state,
            synchronize_adjacency: true,
            apply_lock_policy: true
          )

          assert_equal 'F02', cell_space.storey
          assert_equal [
            :place_cell_group,
            :fixed_state_height_offset,
            :recenter_cell_space_geometry,
            :name_cell_space_entity,
            :register_cell_space,
            :register_state,
            :write_attributes,
            :track_cell_space_entity
          ], calls
          refute_includes calls, :ensure_space_features_groups
          refute_includes calls, :apply_cell_space_material
          refute_includes calls, :synchronize_adjacency_and_transitions_for_cell_space
          refute_includes calls, :apply_indoor_lock_policy
        end

        def test_batch_context_type_change_only_persists_entity_local_state
          calls = []
          context = CellSpaceBatchLifecycleContext.new(
            **callbacks(calls, placed_group: Object.new)
          )
          cell_space = FakeCellSpace.new(Object.new)

          context.persist_type_change(cell_space)

          assert_equal [
            :name_cell_space_entity,
            :write_cell_space_attributes
          ], calls
          refute_includes calls, :apply_cell_space_material
          refute_includes calls, :synchronize_adjacency_and_transitions_for_cell_space
          refute_includes calls, :apply_indoor_lock_policy
        end

        def test_feature_registry_id_index_survives_snapshot_restore
          registry = FeatureRegistry.new
          cell_space = FakeFeature.new('cell-1', FakeGroup.new(101, 201))
          state = FakeState.new('state-1')

          registry.add_cell_space(cell_space)
          registry.add_state(state)

          assert registry.feature_id_in_use?('cell-1')
          assert registry.feature_id_in_use?('state-1')
          assert_same cell_space, registry.feature_by_id('cell-1')

          snapshot = registry.snapshot
          registry.reset!
          refute registry.feature_id_in_use?('cell-1')

          registry.restore!(snapshot)
          assert registry.feature_id_in_use?('cell-1')
          assert registry.feature_id_in_use?('state-1')
          assert_same state, registry.feature_by_id('state-1')

          duplicate = FakeState.new('cell-1')
          error = assert_raises(ArgumentError) do
            registry.add_state(duplicate)
          end
          assert_match(/Duplicate IndoorGML feature id/, error.message)
        end

        private

        def callbacks(calls, placed_group:)
          {
            ensure_space_features_groups: proc { calls << :ensure_space_features_groups },
            place_cell_group: proc { |_group| calls << :place_cell_group; placed_group },
            default_storey_name: proc { 'F01' },
            fixed_state_height_offset: proc { |_cell_space| calls << :fixed_state_height_offset; 1.0 },
            recenter_cell_space_geometry: proc do |_group, fixed_z_offset_from_bottom:|
              calls << :recenter_cell_space_geometry
              refute_nil fixed_z_offset_from_bottom
            end,
            name_cell_space_entity: proc { |_cell_space| calls << :name_cell_space_entity },
            apply_cell_space_material: proc { |_cell_space| calls << :apply_cell_space_material },
            track_cell_space_entity: proc { |_group| calls << :track_cell_space_entity },
            apply_indoor_lock_policy: proc { calls << :apply_indoor_lock_policy },
            register_cell_space: proc { |_cell_space| calls << :register_cell_space; true },
            register_state: proc { |_state| calls << :register_state },
            unregister_cell_space: proc { |_cell_space| calls << :unregister_cell_space },
            unregister_state: proc { |_state| calls << :unregister_state },
            write_attributes: proc { |_cell_space| calls << :write_attributes },
            write_cell_space_attributes: proc { |_cell_space| calls << :write_cell_space_attributes },
            synchronize_adjacency_and_transitions_for_cell_space: proc do |_cell_space|
              calls << :synchronize_adjacency_and_transitions_for_cell_space
            end,
            erase_transitions_for_state: proc { |_state| calls << :erase_transitions_for_state },
            erase_adjacency_for_cell_space: proc { |_cell_space| calls << :erase_adjacency_for_cell_space }
          }
        end
      end
    end
  end
end
