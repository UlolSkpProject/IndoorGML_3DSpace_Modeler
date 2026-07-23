# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      
      class Indoor3DGmlPrimalEntitiesObserver < Sketchup::EntitiesObserver
        include ObserverHelpers

        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
          @indoor_entity_ids = {}
        end

        def onElementAdded(_entities, entity)
          if indoor_gml_entity?(entity)
            track_entity(entity)
            log_event('onElementAdded', entity)
          end
          @indoor_model.primal_entity_added(entity)
        end

        def onElementRemoved(_entities, entity_id)
          return unless untrack_entity_id(entity_id)

          log_removed('onElementRemoved', entity_id)
          @indoor_model.primal_entity_removed(entity_id)
        end

        def track_entity(entity)
          return unless indoor_gml_entity?(entity)

          @indoor_entity_ids[entity.entityID] = true
        end

        def track_entities(entities)
          entities.to_a.each { |entity| track_entity(entity) }
        end

        def clear_tracked_entities
          @indoor_entity_ids.clear
        end

        def untrack_entity_id(entity_id)
          @indoor_entity_ids.delete(entity_id)
        end

      end
    end
  end
end
