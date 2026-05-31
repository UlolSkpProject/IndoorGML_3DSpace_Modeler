# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class Indoor3DGmlDualEntitiesObserver < Sketchup::EntitiesObserver
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onElementAdded(_entities, entity)
          log_event('onElementAdded', entity)
          @indoor_model.dual_entity_added(entity)
        end

        def onElementRemoved(_entities, entity_id)
          log_removed('onElementRemoved', entity_id)
          @indoor_model.dual_entity_removed(entity_id)
        end

        private

        def log_event(event_name, entity)
          puts "[IndoorGML] DualEntitiesObserver##{event_name} #{entity_summary(entity)}"
        end

        def log_removed(event_name, entity_id)
          puts "[IndoorGML] DualEntitiesObserver##{event_name} entity_id=#{entity_id}"
        end

        def entity_summary(entity)
          "class=#{entity.class} entity_id=#{entity.entityID} feature=#{indoor_feature(entity)}"
        rescue StandardError
          "class=#{entity.class}"
        end

        def indoor_feature(entity)
          entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
        rescue StandardError
          nil
        end
      end

    end
  end
end
