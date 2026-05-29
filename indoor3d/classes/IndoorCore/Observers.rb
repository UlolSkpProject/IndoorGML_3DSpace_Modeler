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
          @indoor_model.cell_space_changed(entity)
        end

        def onEraseEntity(entity)
          @indoor_model.cell_space_erased(entity)
        end
      end

      class StateObserver < Sketchup::EntityObserver
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onChangeEntity(entity)
          @indoor_model.state_changed(entity)
        end

        def onEraseEntity(entity)
          @indoor_model.state_erased(entity)
        end
      end

    end
  end
end
