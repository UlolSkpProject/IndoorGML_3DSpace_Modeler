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
      '현재 Geometry를 변경하지 않습니다.',
      'val3dity.exe 기본 검사를 수행합니다.',
      '기본 검사 완료 후 빠른 재검사를 수행합니다.',
      'CellSpace의 정점을 정규화합니다.',
      '이 과정에서 Geometry가 변경될 수 있습니다.',
      'val3dity.exe 검사를 수행합니다.',
      '시험 운영 중인 기능입니다.',
      '일부 모델에서 오류가 발생할 수 있습니다.',
      '실행 전 모델을 저장해 주세요.'
    ].each do |line|
      assert_includes @html, %(<span class="copy-line">#{line}</span>)
    end

    assert_includes(
      @html,
      '<span class="copy-line"><code>--overlap_tol</code> 옵션을 적용하여</span>'
    )
  end

  def test_precision_mode_shows_small_duration_notice_below_overlap_option
    option_index = @html.index('<code>--overlap_tol</code> 옵션을 적용하여')
    notice_index = @html.index('모델 규모에 따라 수십 분이 소요될 수 있습니다.')
    warning_index = @html.index('시험 운영 중인 기능입니다.')

    assert option_index
    assert notice_index
    assert warning_index
    assert_operator option_index, :<, notice_index
    assert_operator notice_index, :<, warning_index
    assert_includes @html, '<span class="mode-note">모델 규모에 따라 수십 분이 소요될 수 있습니다.</span>'
    assert_match(/\.mode-note \{.*?font-size: 10px;/m, @html)
  end

  def test_precision_mode_warns_about_instability_and_saving
    assert_includes @html, '시험 운영 중인 기능입니다.'
    assert_includes @html, '일부 모델에서 오류가 발생할 수 있습니다.'
    assert_includes @html, '실행 전 모델을 저장해 주세요.'
  end
end
