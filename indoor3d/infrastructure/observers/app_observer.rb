# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class Indoor3DGmlAppObserver < Sketchup::AppObserver
        INITIAL_REFRESH_DELAY_SECONDS = 0.5

        def initialize
          super()
          @model_observer = Indoor3DGmlModelObserver.new(on_delete_model: method(:release_model))
          @observed_model_ids = {}
          @initial_refresh_states = {}
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
          cancel_all_validation_sessions
          register_model(model)
          schedule_initial_refresh(model)
        end

        def onOpenModel(model)
          cancel_all_validation_sessions
          register_model(model)
          schedule_initial_refresh(model)
        end

        def expectsStartupModelNotifications
          true
        end

        def schedule_initial_refresh(model)
          return false unless model

          key = model.object_id
          return false if @initial_refresh_states.key?(key)

          # Claim the model before scheduling the timer. Both the extension-load
          # fallback and AppObserver callbacks can reach this method during the
          # same startup sequence.
          @initial_refresh_states[key] = :scheduled
          UI.start_timer(INITIAL_REFRESH_DELAY_SECONDS, false) do
            next unless @initial_refresh_states[key] == :scheduled

            @initial_refresh_states[key] = :running
            begin
              IndoorModel.for(model).refresh_runtime_data(initial_model_load: true)
              @initial_refresh_states[key] = :complete
            rescue StandardError => e
              # A failed refresh may be explicitly scheduled again.
              @initial_refresh_states.delete(key)
              IndoorCore::Logger.puts "[IndoorGML] Runtime refresh failed: #{e.class}: #{e.message}"
            end
          end
          true
        rescue StandardError => e
          @initial_refresh_states.delete(key) if defined?(key) && key
          IndoorCore::Logger.puts "[IndoorGML] Runtime refresh scheduling failed: #{e.class}: #{e.message}"
          false
        end

        def onQuit
          IndoorGmlConverter::ValidationSession.cancel_all(reason: :model_closed) if defined?(IndoorGmlConverter::ValidationSession)
          IndoorGmlConverter::Val3dityRunner.shutting_down!
          IndoorGmlConverter::Val3dityRunner.terminate_all(wait_ms: 0)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Quit cleanup failed: #{e.class}: #{e.message}"
        end

        private

        def cancel_all_validation_sessions
          return unless defined?(IndoorGmlConverter::ValidationSession)

          IndoorGmlConverter::ValidationSession.cancel_all(reason: :model_changed)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation session cleanup on model switch failed: #{e.class}: #{e.message}"
        end

        def release_model(model)
          begin
            key = model&.object_id
            @initial_refresh_states.delete(key) unless key.nil?
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

      end

    end
  end
end
