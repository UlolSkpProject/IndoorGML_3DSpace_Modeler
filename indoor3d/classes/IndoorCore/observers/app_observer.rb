# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class Indoor3DGmlAppObserver < Sketchup::AppObserver
        def initialize
          super()
          @model_observer = Indoor3DGmlModelObserver.new()
          @observed_model_ids = {}
        end

        def register_model(model)
          begin
            return unless model

            key = model.object_id
            return if @observed_model_ids[key]

            model.add_observer(@model_observer)
            @observed_model_ids[key] = true
          rescue StandardError => e
            puts "[IndoorGML] Model observer setup failed: #{e.class}: #{e.message}"
          end
        end

        def onNewModel(model)
          register_model(model)
          refresh_runtime_data()
        end

        def onOpenModel(model)
          register_model(model)
          refresh_runtime_data()
        end

        def expectsStartupModelNotifications
          true
        end

        private

        def refresh_runtime_data
          IndoorModel.current.refresh_runtime_data()
        rescue StandardError => e
          puts "[IndoorGML] Runtime refresh failed: #{e.class}: #{e.message}"
        end
      end

    end
  end
end
