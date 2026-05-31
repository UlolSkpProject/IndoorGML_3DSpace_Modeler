# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

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
