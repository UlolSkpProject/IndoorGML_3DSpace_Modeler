# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/feature_registry'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class FeatureRegistryNormalizedIdLookupTest < Minitest::Test
        FakeGroup = Struct.new(:persistent_id, :entityID)

        FakeCellSpace = Struct.new(:id, :sketchup_group) do
          def sketchup_group_id
            sketchup_group.persistent_id
          end
        end

        def test_lookup_accepts_validation_prefixes
          registry = FeatureRegistry.new
          cell = fake_cell('room_01', 1)
          registry.add_cell_space(cell)

          assert_same cell, registry.find_cell_space_by_normalized_id('room_01')
          assert_same cell, registry.find_cell_space_by_normalized_id('cell_room_01')
          assert_same cell, registry.find_cell_space_by_normalized_id('solid_room_01')
        end

        def test_normalized_collision_keeps_first_registered_match
          registry = FeatureRegistry.new
          first = fake_cell('room:A', 1)
          second = fake_cell('room_A', 2)
          registry.add_cell_space(first)
          registry.add_cell_space(second)

          assert_same first, registry.find_cell_space_by_normalized_id('room_A')
          assert_same first, registry.find_cell_space_by_normalized_id('cell_room_A')
        end

        def test_removing_first_collision_restores_next_match
          registry = FeatureRegistry.new
          first = fake_cell('room:A', 1)
          second = fake_cell('room_A', 2)
          registry.add_cell_space(first)
          registry.add_cell_space(second)

          registry.remove_cell_space(first)

          assert_same second, registry.find_cell_space_by_normalized_id('room_A')
        end

        def test_restore_rebuilds_derived_lookup_index
          registry = FeatureRegistry.new
          first = fake_cell('cell_alpha', 1)
          second = fake_cell('beta', 2)
          registry.add_cell_space(first)
          registry.add_cell_space(second)
          snapshot = registry.snapshot

          registry.reset!
          registry.restore!(snapshot)

          assert_same first, registry.find_cell_space_by_normalized_id('solid_alpha')
          assert_same second, registry.find_cell_space_by_normalized_id('beta')
          assert_nil registry.find_cell_space_by_normalized_id('missing')
        end

        private

        def fake_cell(id, numeric_id)
          FakeCellSpace.new(id, FakeGroup.new(numeric_id, numeric_id + 1000))
        end
      end
    end
  end
end
