# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class Indoor3DGmlModelObserver < Sketchup::ModelObserver
        def onActivePathChanged(model)
          begin
            IndoorModel.current.active_path_changed(model)
          rescue StandardError => e
            puts "[IndoorGML] Active path handling failed: #{e.class}: #{e.message}"
          end
        end
      end

    end
  end
end
