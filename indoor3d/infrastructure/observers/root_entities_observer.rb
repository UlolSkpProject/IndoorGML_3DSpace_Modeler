# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      
      class Indoor3DGmlRootEntitiesObserver < Sketchup::EntitiesObserver
        include ObserverHelpers
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onElementAdded(_entities, entity)
          return unless indoor_gml_entity?(entity)

          log_event('onElementAdded', entity)
          @indoor_model.root_entity_added(entity)
        end

      end
    end
  end
end
