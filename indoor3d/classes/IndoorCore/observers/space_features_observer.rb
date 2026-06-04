# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      
      class SpaceFeaturesObserver < Sketchup::EntityObserver
        include ObserverHelpers
        
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onChangeEntity(entity)
          return unless indoor_gml_entity?(entity)

          log_event('onChangeEntity', entity)
          @indoor_model.space_features_changed(entity)
        end

        def onEraseEntity(entity)
          return unless indoor_gml_entity?(entity)

          log_event('onEraseEntity', entity)
          @indoor_model.space_features_erased(entity)
        end
      end
    end
  end
end
