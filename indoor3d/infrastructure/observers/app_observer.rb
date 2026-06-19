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
            IndoorCore::Logger.puts "[IndoorGML] Model observer setup failed: #{e.class}: #{e.message}"
          end
        end

        def onNewModel(model)
          register_model(model)
          refresh_runtime_data(model)
        end

        def onOpenModel(model)
          register_model(model)
          refresh_runtime_data(model)
        end

        def onCloseModel(model)
          release_model(model)
        end

        def expectsStartupModelNotifications
          true
        end

        def onQuit
          IndoorGmlConverter::Val3dityRunner.terminate_all(wait_ms: 0)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Quit cleanup failed: #{e.class}: #{e.message}"
        end

        private

        def release_model(model)
          begin
            key = model&.object_id
            detach_model_observer(model)
            @model_observer.forget_model(model) if @model_observer.respond_to?(:forget_model)
            @observed_model_ids.delete(key) unless key.nil?
            IndoorModel.release(model)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Model close cleanup failed: #{e.class}: #{e.message}"
          end
        end

        def detach_model_observer(model)
          return unless model && @model_observer
          return unless model.respond_to?(:remove_observer)

          model.remove_observer(@model_observer)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Model observer detach skipped during close: #{e.class}: #{e.message}"
        end

        def cleanup_before_quit
          begin
            IndoorModel.each_instance.each(&:cleanup_before_quit)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Shutdown cleanup failed: #{e.class}: #{e.message}"
          end
        end

        def refresh_runtime_data(model)
          begin
            IndoorModel.for(model).refresh_runtime_data()
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Runtime refresh failed: #{e.class}: #{e.message}"
          end
        end
      end

    end
  end
end
