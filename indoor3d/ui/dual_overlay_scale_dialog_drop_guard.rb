# frozen_string_literal: true

require_relative 'dual_overlay_scale_dialog'
require_relative 'html_dialog_safety'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module DualOverlayScaleDialogDropGuard
        private

        def html
          HtmlDialogSafety.inject_external_file_drop_guard(super)
        end
      end

      DualOverlayScaleDialog.prepend(DualOverlayScaleDialogDropGuard) unless
        DualOverlayScaleDialog.ancestors.include?(DualOverlayScaleDialogDropGuard)
    end
  end
end
