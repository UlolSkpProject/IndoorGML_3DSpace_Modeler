# frozen_string_literal: true
# encoding: UTF-8

require 'minitest/autorun'

class ValidityModeDialogContentTest < Minitest::Test
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

  def test_precision_mode_remains_marked_as_beta
    assert_includes @html, '<span class="mode-title">정밀검사</span>'
  end

  def test_cards_are_equal_height_without_fixed_square_height
    assert_includes @html, 'grid-template-columns: repeat(2, minmax(0, 1fr));'
    assert_includes @html, 'align-items: stretch;'
    assert_includes @html, 'height: 100%;'
    refute_includes @html, 'min-height: 292px;'
    assert_operator @html.index('class="mode fast"'), :<, @html.index('class="mode precision"')
    assert_includes @dialog_source, 'WIDTH = 760'
    assert_includes @dialog_source, 'HEIGHT = 420'
  end

  def test_requested_fast_and_precision_copy_is_present
    [
      '현재 Geometry를 변경하지 않습니다.',
      'val3dity.exe 기본 검사를 수행합니다.',
      '기본 검사 완료 후 빠른 재검사를 수행합니다.',
      '4개 유형 묶음의 Geometry-only 검사로 crash 대상을 찾습니다.',
      'Crash 목록과 LVN 결과를 확인하고 다음 단계로 진행합니다.',
      '모델 규모에 따라 수십 분~수시간이 걸릴 수 있습니다.'
    ].each do |line|
      assert_includes @html, line
    end
  end

  def test_overlap_option_is_inline_code_in_one_non_wrapping_line
    expected = '<span class="copy-line">Crash CellSpace만 정규화한 뒤 <code class="inline-code">--overlap_tol</code> 검사를 수행합니다.</span>'

    assert_includes @html, expected
    assert_match(/\.inline-code \{.*?background: #1b1b1a;.*?font-family: Consolas/m, @html)
  end

  def test_duration_notice_uses_distinct_orange_color
    assert_includes(
      @html,
      '<span class="mode-note">모델 규모에 따라 수십 분~수시간이 걸릴 수 있습니다.</span>'
    )
    assert_match(/\.mode-note \{.*?color: #d3a15c;.*?font-weight: 600;/m, @html)
  end

  def test_yellow_beta_warning_copy_is_removed
    refute_includes @html, '시험 운영 중인 기능입니다.'
    refute_includes @html, '일부 모델에서 오류가 발생할 수 있습니다.'
    refute_includes @html, '실행 전 모델을 저장해 주세요.'
    refute_includes @html, 'class="mode-detail warning"'
  end

  def test_footer_opens_val3dity_release_in_external_browser
    assert_includes @html, 'val3dity 2.2.0 릴리스 ↗'
    assert_includes @html, 'onclick="sketchup.openVal3dityRelease()"'
    assert_includes(
      @dialog_source,
      "VAL3DITY_RELEASE_URL = 'https://github.com/tudelft3d/val3dity/releases#release-2.2.0'"
    )
    assert_includes @dialog_source, "add_action_callback('openVal3dityRelease')"
    assert_includes @dialog_source, 'UI.openURL(url)'
  end
end
