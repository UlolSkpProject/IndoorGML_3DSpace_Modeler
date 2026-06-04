# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      
      class CellSpaceObserver < Sketchup::InstanceObserver
        include ObserverHelpers
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onOpen(instance)
          return unless indoor_gml_entity?(instance)

          log_event('onOpen', instance)
        end

        def onClose(instance)
          return unless indoor_gml_entity?(instance)

          log_event('onClose', instance)
          @indoor_model.cell_space_closed(instance)
        end

        def onChangeEntity(entity)
          return unless indoor_gml_entity?(entity)

          log_event('onChangeEntity', entity)
          @indoor_model.cell_space_changed(entity)
        end

        def onEraseEntity(entity)
          return unless indoor_gml_entity?(entity)

          log_event('onEraseEntity', entity)
          @indoor_model.cell_space_erased(entity)
        end
      end
    end
  end
end
