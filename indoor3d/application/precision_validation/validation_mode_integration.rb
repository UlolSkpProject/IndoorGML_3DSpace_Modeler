# frozen_string_literal: true

require_relative '../../ui/validity_mode_dialog'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        module ValidationModeCommandPatch
          def check_validity(profile: nil)
            return false if validation_operation_running?

            if profile
              return PrecisionValidation.with_profile(profile) do
                super()
              end
            end

            ValidityModeDialog.show do |selected_profile|
              check_validity(profile: selected_profile)
            end
            true
          end

          def check_precision_validity
            check_validity(profile: PRECISION_PROFILE)
          end
        end

        def self.install_validation_mode_selection!
          return true if CommandDispatcher.ancestors.include?(ValidationModeCommandPatch)

          CommandDispatcher.prepend(ValidationModeCommandPatch)
          true
        end
      end

      PrecisionValidation.install_validation_mode_selection!
    end
  end
end
