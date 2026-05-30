# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class CellSpaceObserver < Sketchup::InstanceObserver
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onOpen(instance)
          log_event('onOpen', instance)
        end

        def onClose(instance)
          log_event('onClose', instance)
          @indoor_model.cell_space_changed(instance)
        end

        def onChangeEntity(entity)
          log_event('onChangeEntity', entity)
          @indoor_model.cell_space_changed(entity)
        end

        def onEraseEntity(entity)
          log_event('onEraseEntity', entity)
          @indoor_model.cell_space_erased(entity)
        end

        private

        def log_event(event_name, entity)
          puts "[IndoorGML] CellSpaceObserver##{event_name} #{entity_summary(entity)}"
        end

        def entity_summary(entity)
          "class=#{entity.class} name=#{entity_name(entity)}"
        rescue StandardError
          "class=#{entity.class}"
        end

        def entity_name(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          name.empty? ? '(unnamed)' : name
        end
      end

      class StateObserver < Sketchup::EntityObserver
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onChangeEntity(entity)
          log_event('onChangeEntity', entity)
          @indoor_model.state_changed(entity)
        end

        def onEraseEntity(entity)
          log_event('onEraseEntity', entity)
          @indoor_model.state_erased(entity)
        end

        private

        def log_event(event_name, entity)
          puts "[IndoorGML] StateObserver##{event_name} #{entity_summary(entity)}"
        end

        def entity_summary(entity)
          "class=#{entity.class} name=#{entity_name(entity)}"
        rescue StandardError
          "class=#{entity.class}"
        end

        def entity_name(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          name.empty? ? '(unnamed)' : name
        end
      end

      class SpaceFeaturesObserver < Sketchup::EntityObserver
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onChangeEntity(entity)
          log_event('onChangeEntity', entity)
          @indoor_model.space_features_changed(entity)
        end

        def onEraseEntity(entity)
          log_event('onEraseEntity', entity)
          @indoor_model.space_features_erased(entity)
        end

        private

        def log_event(event_name, entity)
          puts "[IndoorGML] SpaceFeaturesObserver##{event_name} #{entity_summary(entity)}"
        end

        def entity_summary(entity)
          "class=#{entity.class} name=#{entity_name(entity)}"
        rescue StandardError
          "class=#{entity.class}"
        end

        def entity_name(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          name.empty? ? '(unnamed)' : name
        end
      end

      class Indoor3DGmlRootEntitiesObserver < Sketchup::EntitiesObserver
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onElementAdded(_entities, entity)
          log_event('onElementAdded', entity)
          @indoor_model.root_entity_added(entity)
        end

        def onElementRemoved(_entities, entity_id)
          log_removed('onElementRemoved', entity_id)
          @indoor_model.root_entity_removed(entity_id)
        end

        private

        def log_event(event_name, entity)
          puts "[IndoorGML] RootEntitiesObserver##{event_name} #{entity_summary(entity)}"
        end

        def log_removed(event_name, entity_id)
          puts "[IndoorGML] RootEntitiesObserver##{event_name} entity_id=#{entity_id}"
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

      class Indoor3DGmlPrimalEntitiesObserver < Sketchup::EntitiesObserver
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onElementAdded(_entities, entity)
          log_event('onElementAdded', entity)
          @indoor_model.primal_entity_added(entity)
        end

        def onElementRemoved(_entities, entity_id)
          log_removed('onElementRemoved', entity_id)
          @indoor_model.primal_entity_removed(entity_id)
        end

        private

        def log_event(event_name, entity)
          puts "[IndoorGML] PrimalEntitiesObserver##{event_name} #{entity_summary(entity)}"
        end

        def log_removed(event_name, entity_id)
          puts "[IndoorGML] PrimalEntitiesObserver##{event_name} entity_id=#{entity_id}"
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

      class Indoor3DGmlAppObserver < Sketchup::AppObserver
        def onNewModel(_model)
          refresh_runtime_data
        end

        def onOpenModel(_model)
          refresh_runtime_data
        end

        private

        def refresh_runtime_data
          IndoorModel.current.refresh_runtime_data
        rescue StandardError => e
          puts "[IndoorGML] Runtime refresh failed: #{e.class}: #{e.message}"
        end
      end

    end
  end
end
