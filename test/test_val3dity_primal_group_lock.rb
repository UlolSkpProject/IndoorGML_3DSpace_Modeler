# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(*) = nil
      end

      module IndoorGmlConverter
        class Val3dityProcessAdapter
          attr_accessor :finish_result, :terminate_result, :raise_on_start

          def initialize(args:, current_dir:)
            @args = args
            @current_dir = current_dir
            @process_handle = 0
            @finished = false
            @finish_result = false
            @terminate_result = false
          end

          def start(*)
            raise 'start failed' if @raise_on_start

            @process_handle = 123
            true
          end

          def finished?(*)
            @finished = true if @finish_result
            @finish_result
          end

          def terminate(*)
            @terminate_result
          end

          def close(*)
            @process_handle = 0
            true
          end
        end

        class Val3dityRunner
          def initialize(indoor_model, adapter_options = {})
            @indoor_model = indoor_model
            @adapter_options = adapter_options
          end

          def start(*)
            adapter = Val3dityProcessAdapter.new(args: [], current_dir: '.')
            adapter.raise_on_start = @adapter_options[:raise_on_start]
            adapter.start
            adapter
          end
        end
      end
    end
  end
end

require_relative '../indoor3d/validity/val3dity_primal_group_lock'

class FakeVal3dityPrimalGroup
  attr_reader :writes

  def initialize(locked: false, valid: true)
    @locked = locked
    @valid = valid
    @writes = []
  end

  def valid? = @valid
  def locked? = @locked

  def locked=(value)
    @writes << value
    @locked = value
  end
end

FakeVal3dityIndoorModel = Struct.new(:primal_group)

class Val3dityPrimalGroupLockTest < Minitest::Test
  Runner = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityRunner
  Guard = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityPrimalGroupLock::Guard

  def test_locks_only_during_process_and_restores_unlocked_state_on_finish
    group = FakeVal3dityPrimalGroup.new(locked: false)
    adapter = Runner.new(FakeVal3dityIndoorModel.new(group)).start

    assert group.locked?
    adapter.finish_result = false
    refute adapter.finished?
    assert group.locked?

    adapter.finish_result = true
    assert adapter.finished?
    refute group.locked?
    assert_equal [true, false], group.writes
  end

  def test_preserves_preexisting_locked_state
    group = FakeVal3dityPrimalGroup.new(locked: true)
    adapter = Runner.new(FakeVal3dityIndoorModel.new(group)).start

    assert group.locked?
    adapter.finish_result = true
    assert adapter.finished?
    assert group.locked?
    assert_empty group.writes
  end

  def test_successful_termination_restores_lock
    group = FakeVal3dityPrimalGroup.new
    adapter = Runner.new(FakeVal3dityIndoorModel.new(group)).start
    adapter.terminate_result = true

    assert adapter.terminate
    refute group.locked?
  end

  def test_failed_termination_keeps_lock_until_process_finishes
    group = FakeVal3dityPrimalGroup.new
    adapter = Runner.new(FakeVal3dityIndoorModel.new(group)).start
    adapter.terminate_result = false

    refute adapter.terminate
    assert group.locked?

    adapter.finish_result = true
    assert adapter.finished?
    refute group.locked?
  end

  def test_start_failure_restores_lock
    group = FakeVal3dityPrimalGroup.new

    assert_raises(RuntimeError) do
      Runner.new(
        FakeVal3dityIndoorModel.new(group),
        raise_on_start: true
      ).start
    end
    refute group.locked?
  end

  def test_nested_processes_restore_only_after_last_release
    group = FakeVal3dityPrimalGroup.new
    first = Guard.new(group)
    second = Guard.new(group)

    assert first.acquire
    assert second.acquire
    assert group.locked?
    assert first.release
    assert group.locked?
    assert second.release
    refute group.locked?
  end

  def test_invalid_primal_group_is_ignored
    group = FakeVal3dityPrimalGroup.new(valid: false)
    adapter = Runner.new(FakeVal3dityIndoorModel.new(group)).start

    refute group.locked?
    adapter.finish_result = true
    assert adapter.finished?
    refute group.locked?
  end
end
