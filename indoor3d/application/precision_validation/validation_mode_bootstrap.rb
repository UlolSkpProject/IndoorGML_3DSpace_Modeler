# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        # The standalone precision command was used only during the initial
        # implementation bootstrap contract. The production entry point is the existing
        # Check Validity command, followed by the validation mode dialog.
        @precision_command_installed = true
      end
    end
  end
end
