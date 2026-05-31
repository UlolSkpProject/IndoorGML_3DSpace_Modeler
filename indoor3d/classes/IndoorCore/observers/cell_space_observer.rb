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

    end
  end
end
