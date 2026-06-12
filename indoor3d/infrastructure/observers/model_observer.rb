# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class Indoor3DGmlModelObserver < Sketchup::ModelObserver
        def initialize
          super()
          @active_path_keys_by_model_id = {}
          @recovering_unlocked_primal_by_model_id = {}
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

        private

        def handle_active_path_changed(model, source:)
          IndoorCore::Logger.puts "[IndoorGML] active path changed source=#{source}"
          IndoorModel.for(model).active_path_changed(model)
          remember_active_path(model)
        end

        def handle_transaction_replayed(model, source:)
          previous_key_known = remembered_active_path_key?(model)
          previous_key = remembered_active_path_key(model)
          UI.start_timer(0, false) do
            begin
              current_key = active_path_key(model)
              if previous_key_known && previous_key == current_key
                remember_active_path_key(model, current_key)
                recover_unlocked_primal_after_transaction(model)
                next
              end

              handle_active_path_changed(model, source: source)
              recover_unlocked_primal_after_transaction(model)
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Active path #{source} handling failed: #{e.class}: #{e.message}"
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
