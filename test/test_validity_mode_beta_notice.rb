# frozen_string_literal: true
# encoding: UTF-8

require 'minitest/autorun'

class ValidityModeBetaNoticeTest < Minitest::Test
  HTML_PATH = File.expand_path(
    '../indoor3d/ui/html/validity_mode/index.html',
    __dir__
  ).freeze

  def setup
    @html = File.read(HTML_PATH, encoding: 'UTF-8')
  end

  def test_precision_mode_is_marked_as_beta
    assert_includes @html, '<span class="mode-title">정밀검사 (Beta)</span>'
  end

  def test_precision_mode_warns_about_instability_and_saving
    assert_includes(
      @html,
      '시험 운영 중인 기능으로 일부 모델에서 오류가 발생할 수 있습니다. 실행 전 모델을 저장해 주세요.'
    )
  end

  def test_existing_precision_behavior_description_is_preserved
    assert_includes @html, 'CellSpace Normalize를 시도한 뒤'
    assert_includes @html, 'Normalize 성공 CellSpace의 geometry는 미세하게 변경될 수 있으며'
  end
end
