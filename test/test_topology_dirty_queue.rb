# frozen_string_literal: true

require 'minitest/autorun'

module UI
  class << self
    attr_accessor :timers
  end

  def self.start_timer(interval, repeat, &block)
    self.timers ||= []
    timers << { interval: interval, repeat: repeat, block: block }
    true
  end
end

module Sketchup
  class << self
    attr_accessor :test_active_model
  end

  def self.active_model
    @test_active_model
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/application/indoor_model/topology'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class TopologyDirtyQueueTest < Minitest::Test
        def setup
          UI.timers = []
          Sketchup.test_active_model = fake_model
        end

        def teardown
          Sketchup.test_active_model = nil
        end

        def test_flush_clears_queue_after_success
          model = FakeIndoorModel.new(cells: [fake_cell(1), fake_cell(2)])
          model.queue(1, 2)

          model.flush_dirty

          assert_empty model.dirty_pids
          assert_equal false, model.sync_scheduled?
          assert_equal [1, 2], model.synchronized_pids
          assert_equal [1, 2], model.snapshot_pids
          assert_equal true, Sketchup.active_model.active_view.invalidated
          assert_equal true, model.overlay_invalidated
        end

        def test_failed_flush_requeues_failed_and_unprocessed_pids
          model = FakeIndoorModel.new(cells: [fake_cell(1), fake_cell(2), fake_cell(3)], fail_pid: 2)
          model.queue(1, 2, 3)

          model.flush_dirty

          assert_equal [2, 3], model.dirty_pids
          assert_equal true, model.sync_scheduled?
          assert_equal 1, UI.timers.length
          assert_equal [1, 2], model.synchronized_pids
          assert_equal [1], model.snapshot_pids
        end

        def test_replay_invalidates_existing_dirty_timer
          cell = fake_cell(1)
          model = FakeIndoorModel.new(cells: [cell])

          model.mark_dirty(cell)
          assert_equal [1], model.dirty_pids
          assert_equal true, model.sync_scheduled?
          assert_equal 1, UI.timers.length

          model.begin_replay
          UI.timers.first[:block].call

          assert_empty model.dirty_pids
          assert_equal false, model.sync_scheduled?
          assert_empty model.synchronized_pids
          assert_empty model.snapshot_pids

          model.finish_replay
          model.mark_dirty(cell)
          UI.timers.last[:block].call

          assert_equal [1], model.synchronized_pids
          assert_equal [1], model.snapshot_pids
        end

        private

        def fake_cell(pid)
          group = Struct.new(:persistent_id).new(pid)
          Struct.new(:pid, :sketchup_group) do
            def valid?
              true
            end

            def valid_sketchup_group
              sketchup_group
            end
          end.new(pid, group)
        end

        def fake_model
          view = Class.new do
            attr_reader :invalidated

            def invalidate
              @invalidated = true
            end
          end.new
          Struct.new(:active_view).new(view)
        end

        class FakeIndoorModel
          include IndoorModel::Topology

          attr_reader :synchronized_pids, :snapshot_pids, :overlay_invalidated

          def initialize(cells:, fail_pid: nil)
            @feature_registry = FakeRegistry.new(cells)
            @dirty_cell_space_pids = {}
            @cell_space_sync_scheduled = false
            @fail_pid = fail_pid
            @synchronized_pids = []
            @snapshot_pids = []
            @overlay_invalidated = false
            @transaction_replay_pending = false
          end

          def queue(*pids)
            pids.each { |pid| @dirty_cell_space_pids[pid] = true }
          end

          def mark_dirty(cell_space)
            mark_cell_space_dirty(cell_space)
          end

          def begin_replay
            @transaction_replay_pending = true
            invalidate_dirty_cell_space_sync!
          end

          def finish_replay
            @transaction_replay_pending = false
          end

          def dirty_pids
            @dirty_cell_space_pids.keys
          end

          def sync_scheduled?
            @cell_space_sync_scheduled == true
          end

          def flush_dirty
            flush_dirty_cell_space_sync
          end

          def transaction_replay_pending?
            @transaction_replay_pending == true
          end

          private

          def with_transparent_cell_space_operation(_name)
            yield
          end

          def sync
            yield
          end

          def synchronize_adjacency_and_transitions_for_cell_space(cell_space)
            @synchronized_pids << cell_space.pid
            raise 'sync failed' if cell_space.pid == @fail_pid
          end

          def remember_cell_space_change_snapshot(group)
            @snapshot_pids << group.persistent_id
          end

          def invalidate_overlay_transition_points
            @overlay_invalidated = true
          end
        end

        class FakeRegistry
          def initialize(cells)
            @cells = cells.each_with_object({}) { |cell, result| result[cell.pid] = cell }
          end

          def find_cell_space_by_persistent_id(pid)
            @cells[pid]
          end
        end
      end
    end
  end
end
