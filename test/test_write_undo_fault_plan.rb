# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/write_undo_fault_plan'

class TestWriteUndoFaultPlan < Minitest::Test
  Plan = ULOL::Indoor3DGmlModeler::IndoorCore::
    ThreadedProgressInfrastructure::WriteUndoFaultPlan

  def test_disabled_faults
    plan = Plan.new(item_count: 500)

    refute plan.cancellation_enabled?
    refute plan.failure_enabled?
    refute plan.cancel_after_prepare?(500)
    refute plan.fail_before_next_create?(500)
  end

  def test_prepare_cancellation_threshold
    plan = Plan.new(
      item_count: 500,
      cancel_after_prepared_items: 125
    )

    refute plan.cancel_after_prepare?(124)
    assert plan.cancel_after_prepare?(125)
    assert plan.cancel_after_prepare?(126)
  end

  def test_apply_failure_threshold
    plan = Plan.new(
      item_count: 500,
      fail_after_created_items: 120
    )

    refute plan.fail_before_next_create?(119)
    assert plan.fail_before_next_create?(120)
    assert plan.fail_before_next_create?(121)
  end

  def test_rejects_invalid_thresholds
    assert_raises(ArgumentError) do
      Plan.new(item_count: 500, cancel_after_prepared_items: 0)
    end
    assert_raises(ArgumentError) do
      Plan.new(item_count: 500, cancel_after_prepared_items: 501)
    end
    assert_raises(ArgumentError) do
      Plan.new(item_count: 500, fail_after_created_items: 0)
    end
    assert_raises(ArgumentError) do
      Plan.new(item_count: 500, fail_after_created_items: 500)
    end
  end
end
