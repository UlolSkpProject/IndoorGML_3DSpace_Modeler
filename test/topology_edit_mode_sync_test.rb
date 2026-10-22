# frozen_string_literal: true

require 'minitest/autorun'

unless defined?(UI)
  module UI
    def self.start_timer(_delay, _repeat, &block)
      block.call
      1
    end
  end
end

require_relative '../indoor3d/application/indoor_model/topology'

class TopologyEditModeSyncTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore

  class Harness
    include Core::IndoorModel::Topology

    attr_reader :flush_count

    def initialize
      @queue = Core::DirtyTopologyQueue.new
      @queue.mark(123)
      @flush_count = 0
    end

    def dirty_topology_queue
      @queue
    end

    def editing?
      true
    end

    def transaction_replay_pending?
      false
    end

    private

    def flush_dirty_cell_space_sync
      @flush_count += 1
    end
  end

  def test_scheduled_dirty_sync_runs_while_edit_mode_is_active
    harness = Harness.new

    harness.send(:schedule_dirty_cell_space_sync)

    assert_equal 1, harness.flush_count
  end
end
