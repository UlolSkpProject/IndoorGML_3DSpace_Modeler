# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # A legacy/dev runtime profiler can display this diagnostic directly through
      # UI.messagebox, bypassing UiFeedback. Suppress only this exact diagnostic
      # family; all application confirmations and other message boxes remain
      # untouched.
      module InitialRuntimeLoadDiagnosticMessageboxGuard
        MESSAGE_PREFIX = 'IndoorGML initial runtime load'

        def messagebox(message, *arguments)
          if message.to_s.start_with?(MESSAGE_PREFIX)
            IndoorCore::Logger.puts(
              '[IndoorGML] Initial runtime load diagnostic messagebox suppressed'
            )
            return defined?(IDOK) ? IDOK : 1
          end

          super
        end
      end

      if defined?(UI) && UI.respond_to?(:messagebox)
        singleton = UI.singleton_class
        singleton.prepend(
          InitialRuntimeLoadDiagnosticMessageboxGuard
        ) unless singleton.ancestors.include?(
          InitialRuntimeLoadDiagnosticMessageboxGuard
        )
      end

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

            unless initial_runtime_refresh_applicable?(model)
              @initial_refresh_states[key] = :skipped
              IndoorCore::Logger.puts(
                '[IndoorGML] Initial runtime refresh skipped: ' \
                'no PrimalSpaceFeatures with persisted CellSpace'
              )
              next
            end

            @initial_refresh_states[key] = :running
            begin
              run_initial_refresh_without_modal_feedback(model)
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

        def initial_runtime_refresh_applicable?(model)
          return false unless model&.respond_to?(:entities)

          root_entities = model.entities
          return false unless root_entities&.respond_to?(:to_a)

          root_entities.to_a.any? do |entity|
            initial_runtime_primal_group?(entity) &&
              persisted_cell_space_inside?(entity)
          end
        rescue StandardError => e
          IndoorCore::Logger.puts(
            "[IndoorGML] Initial runtime refresh preflight failed: " \
            "#{e.class}: #{e.message}"
          )
          false
        end

        def initial_runtime_primal_group?(entity)
          return false unless valid_runtime_entity?(entity)
          return false unless entity.respond_to?(:entities)

          feature = indoor_feature_value(entity)
          feature == IndoorModel::PRIMAL_GROUP_FEATURE ||
            (entity.respond_to?(:name) && entity.name.to_s == IndoorModel::PRIMAL_GROUP_NAME)
        rescue StandardError
          false
        end

        def persisted_cell_space_inside?(primal_group)
          scan_persisted_cell_space_entities(primal_group.entities, {})
        rescue StandardError
          false
        end

        def scan_persisted_cell_space_entities(entities, visited)
          return false unless entities&.respond_to?(:to_a)

          entities.to_a.any? do |entity|
            next false unless valid_runtime_entity?(entity)
            next true if indoor_feature_value(entity) == 'CellSpace'

            nested_entities = runtime_nested_entities(entity)
            next false unless nested_entities

            key = nested_entities.object_id
            next false if visited[key]

            visited[key] = true
            scan_persisted_cell_space_entities(nested_entities, visited)
          end
        end

        def runtime_nested_entities(entity)
          return entity.entities if entity.respond_to?(:entities) && entity.entities

          definition = entity.definition if entity.respond_to?(:definition)
          return definition.entities if definition&.respond_to?(:entities)

          nil
        rescue StandardError
          nil
        end

        def indoor_feature_value(entity)
          return '' unless entity.respond_to?(:get_attribute)

          entity.get_attribute(
            IndoorModel::ATTRIBUTE_DICTIONARY_NAME,
            'feature'
          ).to_s
        rescue StandardError
          ''
        end

        def valid_runtime_entity?(entity)
          return false if entity.nil?
          return entity.valid? == true if entity.respond_to?(:valid?)

          true
        rescue StandardError
          false
        end

        def run_initial_refresh_without_modal_feedback(model)
          refresh = proc do
            IndoorModel.for(model).refresh_runtime_data(initial_model_load: true)
          end
          if defined?(UiFeedback) && UiFeedback.respond_to?(:with_modal_suppressed)
            UiFeedback.with_modal_suppressed(reason: :initial_runtime_refresh) do
              refresh.call
            end
          else
            refresh.call
          end
        end

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
