# frozen_string_literal: true

require 'json'
require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module HtmlDialogMetrics
          WINDOW_CHROME_HEIGHT = 0
        end
      end
    end
  end
end

require_relative '../indoor3d/ui/export_progress_dialog'
require_relative '../indoor3d/validity/val3dity_report_renderer'

class ValidationFocusDialogAckTest < Minitest::Test
  DialogClass = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::ExportProgressDialog
  Renderer = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityReportRenderer

  class FakeHtmlDialog
    attr_reader :scripts

    def initialize
      @scripts = []
    end

    def execute_script(script)
      @scripts << script
    end
  end

  def setup
    @progress = DialogClass.new
    @dialog = FakeHtmlDialog.new
  end

  def focus(ids, row_id = 'A')
    @progress.send(:handle_validation_focus_cells, @dialog, ids, '104', [], [], row_id)
    @dialog.scripts.last
  end

  def test_deselection_sends_successful_ack
    @progress.on_validation_focus_cells { true }
    script = focus([], '')
    assert_includes script, 'completeValidationFocusRowDeselection('
    assert_includes script, '"ok":true'
  end

  def test_deselection_failure_always_releases_pending_ui
    @progress.on_validation_focus_cells { false }
    script = focus([], '')
    assert_includes script, 'completeValidationFocusRowDeselection('
    assert_includes script, '"ok":false'
  end

  def test_callback_exception_sends_deselection_failure_ack
    @progress.on_validation_focus_cells { raise 'interrupted focus reset' }
    script = focus([], '')
    assert_includes script, 'completeValidationFocusRowDeselection('
    assert_includes script, '"ok":false'
    assert_includes script, 'interrupted focus reset'
  end

  def test_selected_row_waits_for_success_ack
    @progress.on_validation_focus_cells { { ok: true, status: :success, row_id: 'A' } }
    script = focus(['cell-A'])
    assert_includes script, 'completeValidationFocusRowSelection('
    assert_includes script, '"rowId":"A"'
    assert_includes script, '"ok":true'
  end

  def test_selected_row_partial_ack_contains_warning
    @progress.on_validation_focus_cells { { ok: true, status: :partial, warnings: ['Camera failed'] } }
    script = focus(['cell-A'])
    assert_includes script, '"status":"partial"'
    assert_includes script, 'Camera failed'
  end

  def test_selected_row_failure_does_not_claim_success
    @progress.on_validation_focus_cells { false }
    script = focus(['cell-A'])
    assert_includes script, '"ok":false'
    assert_includes script, 'completeValidationFocusRowSelection('
  end

  def test_renderer_keeps_deselect_before_next_row_transition
    script = Renderer.new.send(:report_filter_script)
    assert_includes script, 'validationFocusDeselectionInProgress = true'
    assert_includes script, "sketchup.focusValidationCells([], '', [], [], '')"
    assert_includes script, 'payload.ok !== true'
    assert_includes script, 'Never activate the queued Row'
    assert_includes script, 'completeValidationFocusRowSelection'
    assert_includes script, 'pendingValidationFocusChange'
  end

  def test_renderer_preserves_existing_focus_class_and_row_editing
    script = Renderer.new.send(:report_filter_script)
    assert_includes script, "attempted.classList.add('focused')"
    assert_includes script, 'attempted.open = true'
    assert_includes script, 'window.updateValidationFocusRow = function(payload)'
    assert_includes script, 'window.clearValidationFocusSelection = function()'
  end
end
