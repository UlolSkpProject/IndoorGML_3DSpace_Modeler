# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/ui/cell_space_create_dialog'

class CellSpaceCreateDialogTest < Minitest::Test
  Dialog = ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceCreateDialog
  Result = Struct.new(:converted_count, :errors, :metrics, keyword_init: true)

  def test_result_payload_reports_success
    payload = Dialog.result_payload(
      Result.new(
        converted_count: 2,
        errors: [],
        metrics: { total_duration: 1.25 }
      ),
      title: 'CellSpace 생성 완료'
    )

    assert_equal 'success', payload[:status]
    assert_equal 2, payload[:converted_count]
    assert_equal 0, payload[:error_count]
    assert_equal 1.25, payload.dig(:metrics, :total)
  end

  def test_result_payload_reports_partial_failure
    payload = Dialog.result_payload(
      Result.new(
        converted_count: 1,
        errors: [{ group: 'Room 01', reason: 'Invalid solid' }],
        metrics: {}
      ),
      title: 'CellSpace 변환 완료'
    )

    assert_equal 'warning', payload[:status]
    assert_equal 1, payload[:converted_count]
    assert_equal 1, payload[:error_count]
    assert_equal 'Room 01', payload[:errors].first[:group]
  end

  def test_result_payload_reports_failure
    payload = Dialog.result_payload(
      Result.new(
        converted_count: 0,
        errors: [{ group: 'Room 01', reason: 'Invalid solid' }],
        metrics: {}
      ),
      title: 'CellSpace 변환 완료'
    )

    assert_equal 'error', payload[:status]
  end
end
