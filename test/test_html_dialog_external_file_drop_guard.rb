# frozen_string_literal: true

require 'minitest/autorun'

class HtmlDialogExternalFileDropGuardTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_repository_has_three_html_dialog_constructors
    sources = Dir.glob(File.join(ROOT, 'indoor3d', '**', '*.rb')).map { |path| File.read(path) }
    count = sources.sum { |source| source.scan('UI::HtmlDialog.new').length }

    assert_equal 3, count
  end

  def test_guard_detects_files_from_files_collection_and_types
    source = File.read(
      File.join(ROOT, 'indoor3d/ui/html/shared/external_file_drop_guard.js')
    )

    assert_includes source, 'dataTransfer.files?.length > 0'
    assert_includes source, "Array.from(dataTransfer.types || []).includes('Files')"
    assert_includes source, "window.addEventListener(\n    'dragover'"
    assert_includes source, "window.addEventListener(\n    'drop'"
    assert_includes source, 'event.preventDefault()'
    assert_includes source, "event.dataTransfer.dropEffect = 'none'"
    assert_includes source, 'if (!isExternalFileDrag(event)) return;'
    refute_includes source, 'event.stopPropagation()'
  end

  def test_guard_initialization_is_idempotent
    source = File.read(
      File.join(ROOT, 'indoor3d/ui/html/shared/external_file_drop_guard.js')
    )

    assert_includes source, 'window.__indoorGmlExternalFileDropGuardInitialized'
  end

  def test_set_file_dialog_entries_load_and_initialize_shared_guard
    %w[
      indoor3d/ui/html/edit_mode/index.html
      indoor3d/ui/html/export_progress/index.html
    ].each do |relative_path|
      source = File.read(File.join(ROOT, relative_path))

      assert_includes source, '../shared/external_file_drop_guard.js'
      assert_includes source, 'initExternalFileDropGuard();'
    end
  end

  def test_dynamic_html_surfaces_reuse_same_guard_source
    helper = File.read(File.join(ROOT, 'indoor3d/ui/html_dialog_safety.rb'))
    dual = File.read(File.join(ROOT, 'indoor3d/ui/dual_overlay_scale_dialog_drop_guard.rb'))
    report = File.read(File.join(ROOT, 'indoor3d/validity/val3dity_report_drop_guard.rb'))

    assert_includes helper, "'external_file_drop_guard.js'"
    assert_includes helper, 'initExternalFileDropGuard();'
    assert_includes dual, 'HtmlDialogSafety.inject_external_file_drop_guard(super)'
    assert_includes report, 'HtmlDialogSafety.inject_external_file_drop_guard(super)'
  end

  def test_existing_dragstart_policies_are_not_removed
    edit_mode = File.read(File.join(ROOT, 'indoor3d/ui/html/edit_mode/app.js'))
    export_progress = File.read(File.join(ROOT, 'indoor3d/ui/html/export_progress/app.js'))
    report = File.read(File.join(ROOT, 'indoor3d/validity/val3dity_report_renderer.rb'))

    assert_includes edit_mode, "document.addEventListener('dragstart'"
    assert_includes export_progress, "document.addEventListener('dragstart'"
    assert_includes report, "document.addEventListener('dragstart'"
  end
end
