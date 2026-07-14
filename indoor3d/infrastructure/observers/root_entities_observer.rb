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

        def onElementRemoved(_entities, entity_id)
          return unless @indoor_entity_ids.delete(entity_id)

          log_removed('onElementRemoved', entity_id)
          @indoor_model.root_entity_removed(entity_id)
        end

        def track_entity(entity)
          return unless entity

          @indoor_entity_ids[entity.entityID] = true
        rescue StandardError
          nil
        end

        def clear_tracked_entities
          @indoor_entity_ids.clear
        end

      end
    end
  end
end
