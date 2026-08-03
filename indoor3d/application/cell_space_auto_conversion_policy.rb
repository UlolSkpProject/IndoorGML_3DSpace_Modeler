# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Compatibility support for models written by the earlier marker-based
      # automatic-conversion policy. Tag-based CellSpace creation is now limited
      # to the explicit Create CellSpace workflow, so no new marker is required.
      module CellSpaceAutoConversionPolicy
        DICTIONARY_NAME = 'ULOL_Indoor3D_Policy'
        AUTO_CONVERSION_DISABLED_KEY = 'cell_space_auto_conversion_disabled'

        module_function

        def disabled?(entity)
          return false unless entity&.respond_to?(:get_attribute)

          entity.get_attribute(
            DICTIONARY_NAME,
            AUTO_CONVERSION_DISABLED_KEY,
            false
          ) == true
        rescue StandardError
          false
        end

        # Retained only for backward-compatible tests/tools that may inspect or
        # migrate an older file. Production Create/Demotion flows do not call it.
        def disable!(entity)
          return false unless entity&.respond_to?(:set_attribute)

          entity.set_attribute(
            DICTIONARY_NAME,
            AUTO_CONVERSION_DISABLED_KEY,
            true
          )
          disabled?(entity)
        rescue StandardError
          false
        end

        def enable!(entity)
          return true unless entity
          return true unless entity.respond_to?(:delete_attribute)

          entity.delete_attribute(
            DICTIONARY_NAME,
            AUTO_CONVERSION_DISABLED_KEY
          )
          !disabled?(entity)
        rescue StandardError
          false
        end
      end
    end
  end
end
