# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Persists the user's explicit decision to keep a Tag-mapped solid as a
      # plain SketchUp group. The marker lives outside the IndoorGML dictionary
      # so clearing IndoorGML semantics cannot erase the decision.
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
