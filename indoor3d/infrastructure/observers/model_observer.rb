# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class Indoor3DGmlModelObserver < Sketchup::ModelObserver
        def initialize
          super()
          @active_path_keys_by_model_id = {}
          @recovering_unlocked_primal_by_model_id = {}
          @transaction_generations_by_model_id = {}
        end

        def onActivePathChanged(model)
          begin
            handle_active_path_changed(model, source: :active_path_changed)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Active path handling failed: #{e.class}: #{e.message}"
          end
        end

        def onTransactionUndo(model)
          handle_transaction_replayed(model, source: :undo)
        end

        def onTransactionRedo(model)
          handle_transaction_replayed(model, source: :redo)
        end

        def forget_model(model)
          key = model&.object_id
          return if key.nil?

          @active_path_keys_by_model_id.delete(key)
          @recovering_unlocked_primal_by_model_id.delete(key)
          transaction_generations_by_model_id.delete(key)
        end

        private

        def handle_active_path_changed(model, source:)
          IndoorCore::Logger.puts "[IndoorGML] active path changed source=#{source}"
          indoor_model = IndoorModel.for(model)
          unless indoor_model.transaction_replay_pending?
            indoor_model.active_path_changed(model)
          end
          remember_active_path(model)
        end

        def handle_transaction_replayed(model, source:)
          key = model&.object_id
          return if key.nil?

          generations = transaction_generations_by_model_id
          generation = generations[key].to_i + 1
          generations[key] = generation
          IndoorModel.for(model).begin_transaction_replay(source: source, generation: generation)
          UI.start_timer(0, false) do
            indoor_model = nil
            begin
              next unless transaction_generations_by_model_id[key] == generation

              indoor_model = IndoorModel.for(model)
              indoor_model.reconcile_runtime_after_transaction(source: source, generation: generation)
              remember_active_path(model)
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Active path #{source} handling failed: #{e.class}: #{e.message}"
            ensure
              if transaction_generations_by_model_id[key] == generation
                begin
                  indoor_model ||= IndoorModel.for(model)
                rescue StandardError
                  indoor_model = nil
                end
                indoor_model&.finish_transaction_replay(generation: generation)
              end
            end
          end
        end

        def recover_unlocked_primal_after_transaction(model)
          key = model.object_id
          return if @recovering_unlocked_primal_by_model_id[key]

          @recovering_unlocked_primal_by_model_id[key] = true
          IndoorModel.for(model).recover_unlocked_primal_after_transaction(model)
        ensure
          @recovering_unlocked_primal_by_model_id.delete(key) if @recovering_unlocked_primal_by_model_id
        end

        def transaction_generations_by_model_id
          @transaction_generations_by_model_id ||= {}
        end

        def remember_active_path(model)
          remember_active_path_key(model, active_path_key(model))
        end

        def remember_active_path_key(model, key)
          @active_path_keys_by_model_id[model.object_id] = key
        end

        def remembered_active_path_key(model)
          @active_path_keys_by_model_id[model.object_id]
        end

        def remembered_active_path_key?(model)
          @active_path_keys_by_model_id.key?(model.object_id)
        end

        def active_path_key(model)
          path = model&.active_path
          return nil if path.nil?

          path.map { |entity| active_path_entity_key(entity) }
        end

        def active_path_entity_key(entity)
          return nil unless entity&.valid?
          return entity.persistent_id if entity.respond_to?(:persistent_id)

          entity.object_id
        end
      end

    end
  end
end
