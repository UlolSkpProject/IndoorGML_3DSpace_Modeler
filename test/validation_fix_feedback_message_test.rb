# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/ui/commands/export_commands'

class ValidationFixFeedbackMessageTest < Minitest::Test
  ExportCommands = ULOL::Indoor3DGmlModeler::IndoorCore::ExportCommands

  class Harness
    include ExportCommands
  end

  def setup
    @harness = Harness.new
  end

  def test_success_payload_reports_counts_and_details_for_custom_messagebox
    payload = @harness.validation_fix_feedback_payload(
      fixed: 1,
      skipped: 0,
      failed: 0,
      message: '701 수정 완료',
      details: ['Window 경계 face 정사영 완료']
    )

    assert_equal '자동 수정 성공', payload[:feedbackTitle]
    assert_includes payload[:feedbackMessage], '수정 1건 / 건너뜀 0건 / 실패 0건'
    assert_includes payload[:feedbackMessage], 'Window 경계 face 정사영 완료'
  end

  def test_failure_and_manual_payload_titles
    failed = @harness.validation_fix_feedback_payload(
      fixed: 0, skipped: 0, failed: 1, message: 'solid 검증 실패'
    )
    skipped = @harness.validation_fix_feedback_payload(
      fixed: 0, skipped: 1, failed: 0, message: '수동 수정 필요'
    )

    assert_equal '자동 수정 실패', failed[:feedbackTitle]
    assert_equal '자동 수정 불가 — 수동 수정 필요', skipped[:feedbackTitle]
  end

  def test_mixed_result_is_reported_as_partial_success
    payload = @harness.validation_fix_feedback_payload(
      fixed: 1, skipped: 1, failed: 0, message: '일부 정상화, 수동 수정 필요'
    )

    assert_equal '자동 수정 일부 성공', payload[:feedbackTitle]
  end

  def test_bulk_result_message_contains_only_success_and_failure_counts
    payload = @harness.validation_fix_feedback_payload(
      code: 701, rowId: '', fixed: 7, skipped: 2, failed: 1,
      message: 'details must not be shown', details: ['verbose detail']
    )

    assert_equal true, payload[:bulk]
    assert_equal '일괄 수정 결과', payload[:feedbackTitle]
    assert_equal '성공 7건 / 실패 3건', payload[:feedbackMessage]
  end
end
