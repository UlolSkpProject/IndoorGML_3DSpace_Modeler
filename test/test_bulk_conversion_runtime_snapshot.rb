# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/feature_registry'
require_relative '../indoor3d/application/topology_coordinator'
require_relative '../indoor3d/infrastructure/scene/scene_group_guard'
require_relative '../indoor3d/application/indoor_model/runtime_support'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class BulkConversionRuntimeSnapshotTest < Minitest::Test
        def test_restore_returns_primal_group_to_existing_reference
          model = FakeIndoorModel.new
          old_group = Object.new
          temporary_group = Object.new
          model.primal_group = old_group

          snapshot = model.bulk_snapshot
          model.primal_group = temporary_group
          model.restore_bulk_snapshot(snapshot)

          assert_same old_group, model.primal_group
        end

        def test_restore_returns_primal_group_to_nil
          model = FakeIndoorModel.new
          temporary_group = Object.new
          model.primal_group = nil

          snapshot = model.bulk_snapshot
          model.primal_group = temporary_group
          model.restore_bulk_snapshot(snapshot)

          assert_nil model.primal_group
        end

        def test_restore_returns_dirty_queue_and_scheduled_flag
          model = FakeIndoorModel.new
          model.queue_dirty(101)
          model.sync_scheduled = true

          snapshot = model.bulk_snapshot
          model.queue_dirty(202)
          model.clear_dirty_queue
          model.sync_scheduled = false
          model.restore_bulk_snapshot(snapshot)

          assert_equal [101], model.dirty_pids
          assert_equal true, model.sync_scheduled?
        end

        def test_restore_returns_scene_group_guard_tracking
          model = FakeIndoorModel.new
          group_a = FakeGroup.new(1, 'Wrong A')
          group_b = FakeGroup.new(2, 'Wrong B')
          group_c = FakeGroup.new(3, 'Wrong C')
          model.scene_group_guard.track(group_a, 'Expected A')
          model.scene_group_guard.track(group_b, 'Expected B')
          snapshot = model.bulk_snapshot

          model.scene_group_guard.track(group_c, 'Expected C')
          model.scene_group_guard.track(group_a, 'Changed A')
          model.restore_bulk_snapshot(snapshot)
          model.scene_group_guard.enforce([group_a, group_b, group_c])

          assert_equal 'Expected A', group_a.name
          assert_equal 'Expected B', group_b.name
          assert_equal 'Wrong C', group_c.name
        end

        def test_scene_group_guard_snapshot_is_independent_copy
          guard = SceneGroupGuard.new(with_unlocked: proc { |_group, &block| block.call })
          group = FakeGroup.new(1, 'Wrong')
          guard.track(group, 'Expected')
          snapshot = guard.snapshot
          snapshot[group.persistent_id] = 'Mutated'

          guard.enforce([group])

          assert_equal 'Expected', group.name
        end

        def test_scene_group_guard_restore_uses_independent_copy
          guard = SceneGroupGuard.new(with_unlocked: proc { |_group, &block| block.call })
          group = FakeGroup.new(1, 'Wrong')
          snapshot = { group.persistent_id => 'Expected' }
          guard.restore!(snapshot)
          snapshot[group.persistent_id] = 'Mutated'

          guard.enforce([group])

          assert_equal 'Expected', group.name
        end

        private

        class FakeIndoorModel
          include IndoorModel::RuntimeSupport

          attr_accessor :primal_group
          attr_writer :sync_scheduled
          attr_reader :scene_group_guard

          def initialize
            @feature_registry = FeatureRegistry.new
            @cell_space_change_snapshots = {}
            @space_features_change_snapshots = {}
            @topology_coordinator = TopologyCoordinator.new(dirty_queue: DirtyTopologyQueue.new)
            @cell_space_observed_ids = {}
            @space_features_observed_ids = {}
            @entities_observed_ids = {}
            @states = []
            @transitions = []
            @primal_group = nil
            @scene_group_guard = SceneGroupGuard.new(with_unlocked: proc { |_group, &block| block.call })
            bind_registry_collections
          end

          def bulk_snapshot
            bulk_conversion_runtime_snapshot
          end

          def restore_bulk_snapshot(snapshot)
            restore_bulk_conversion_runtime(snapshot)
          end

          def queue_dirty(pid)
            dirty_topology_queue.mark(pid)
          end

          def clear_dirty_queue
            dirty_topology_queue.clear
          end

          def dirty_pids
            dirty_topology_queue.persistent_ids
          end

          def sync_scheduled?
            dirty_topology_queue.scheduled?
          end

          def sync_scheduled=(value)
            value ? dirty_topology_queue.schedule! : dirty_topology_queue.unschedule!
          end
        end

        class FakeGroup
          attr_accessor :name
          attr_reader :persistent_id

          def initialize(persistent_id, name)
            @persistent_id = persistent_id
            @name = name
          end

          def valid?
            true
          end
        end
      end
    end
  end
end
