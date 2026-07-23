# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/feature_registry'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class FeatureRegistryPairIndexTest < Minitest::Test
        def test_pair_indexes_follow_add_delete_and_restore
          registry = FeatureRegistry.new
          transition = Struct.new(:id).new('transition-1')
          registry.set_adjacent_pair('A:B', Object.new, Object.new)
          registry.set_adjacent_pair('A:C', Object.new, Object.new)
          registry.add_transition(transition, pair_key: 'A:B')
          snapshot = registry.snapshot

          assert_equal %w[A:B A:C], registry.adjacent_pair_keys_for_cell('A').sort
          assert_equal ['A:B'], registry.transition_pair_keys_for_cell('B')

          registry.delete_adjacent_pair('A:B')
          registry.delete_transition_for_pair('A:B')
          assert_equal ['A:C'], registry.adjacent_pair_keys_for_cell('A')
          assert_empty registry.transition_pair_keys_for_cell('B')

          registry.restore!(snapshot)
          assert_equal %w[A:B A:C], registry.adjacent_pair_keys_for_cell('A').sort
          assert_equal ['A:B'], registry.transition_pair_keys_for_cell('B')
        end
      end
    end
  end
end
