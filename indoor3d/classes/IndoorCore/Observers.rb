# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class CellSpaceObserver < Sketchup::EntityObserver
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
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

    end
  end
end
