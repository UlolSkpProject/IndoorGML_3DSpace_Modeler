# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      
      class Indoor3DGmlRootEntitiesObserver < Sketchup::EntitiesObserver
        include ObserverHelpers
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
          @indoor_entity_ids = {}
        end

        def onElementAdded(_entities, entity)
          return unless indoor_gml_entity?(entity)

          track_entity(entity)
          log_event('onElementAdded', entity)
          @indoor_model.root_entity_added(entity)
        end

        def track_entity(entity)
          return unless entity&.valid?

          @indoor_entity_ids[entity.entityID] = true
        end

        private

        def untrack_entity_id(entity_id)
          @indoor_entity_ids.delete(entity_id)
        end

      end
    end
  end
end
