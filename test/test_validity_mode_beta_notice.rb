# frozen_string_literal: true
# encoding: UTF-8

require 'minitest/autorun'

class ValidityModeBetaNoticeTest < Minitest::Test
  HTML_PATH = File.expand_path(
    '../indoor3d/ui/html/validity_mode/index.html',
    __dir__
  ).freeze
  DIALOG_PATH = File.expand_path(
    '../indoor3d/ui/validity_mode_dialog.rb',
    __dir__
  ).freeze

  def setup
    @html = File.read(HTML_PATH, encoding: 'UTF-8')
    @dialog_source = File.read(DIALOG_PATH, encoding: 'UTF-8')
  end

  def test_precision_mode_is_marked_as_beta
    assert_includes @html, '<span class="mode-title">정밀검사 (Beta)</span>'
  end

  def test_modes_are_equal_width_cards_in_left_to_right_order
    assert_includes @html, 'grid-template-columns: repeat(2, minmax(0, 1fr));'
    assert_includes @html, 'min-height: 292px;'
    assert_operator @html.index('class="mode fast"'), :<, @html.index('class="mode precision"')
    assert_includes @dialog_source, 'WIDTH = 720'
    assert_includes @dialog_source, 'HEIGHT = 500'
  end

  def test_copy_uses_explicit_non_wrapping_lines
    assert_includes @html, 'white-space: nowrap;'

    [
      '현재 geometry를 변경하지 않습니다.',
      '일반 validity를 확인합니다.',
      'CellSpace Normalize를 먼저 수행합니다.',
      '0.01 mm를 GML 좌표 단위로 변환해',
      '시험 운영 중인 기능입니다.',
      '일부 모델에서 오류가 발생할 수 있습니다.',
      '실행 전 모델을 저장해 주세요.',
      'Normalize 성공 CellSpace의 geometry는',
      '미세하게 변경될 수 있습니다.',
      'Extension recheck는 실행하지 않습니다.'
    ].each do |line|
      assert_includes @html, %(<span class="copy-line">#{line}</span>)
    end
  end

  def test_precision_mode_warns_about_instability_and_saving
    assert_includes @html, '시험 운영 중인 기능입니다.'
    assert_includes @html, '일부 모델에서 오류가 발생할 수 있습니다.'
    assert_includes @html, '실행 전 모델을 저장해 주세요.'
  end
end
