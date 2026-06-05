# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class Indoor3DGmlSelectionObserver < Sketchup::SelectionObserver
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onSelectionBulkChange(_selection)
          @indoor_model.selection_changed()
        end

        def onSelectionCleared(_selection)
          @indoor_model.selection_changed()
        end

        def onSelectionAdded(_selection, _entity)
          @indoor_model.selection_changed()
        end

        def onSelectionRemoved(_selection, _entity)
          @indoor_model.selection_changed()
        end
      end

    end
  end
end
