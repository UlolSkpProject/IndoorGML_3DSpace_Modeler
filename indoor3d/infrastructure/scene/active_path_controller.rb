# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class ActivePathController
        def initialize(model, logger: nil)
          @model = model
          @logger = logger || (defined?(IndoorCore::Logger) && IndoorCore::Logger)
        end

        def snapshot
          path = @model&.active_path
          path ? path.dup : nil
        rescue StandardError => e
          log("active path snapshot failed: #{e.class}: #{e.message}")
          nil
        end

        def close_to_root
          return false unless @model

          @model.close_active while @model.active_path
          true
        rescue StandardError => e
          log("active path close failed: #{e.class}: #{e.message}")
          false
        end

        def restore(path, close_when_nil: true)
          return close_to_root if path.nil? && close_when_nil
          return false if path.nil?

          valid_path = Array(path).select { |entity| entity&.valid? }
          return close_to_root if valid_path.empty? && close_when_nil
          return false if valid_path.empty?
          return false unless @model.respond_to?(:active_path=)

          @model.active_path = valid_path
          true
        rescue StandardError => e
          log("active path restore failed: #{e.class}: #{e.message}")
          false
        end

        def set(path)
          return false unless @model.respond_to?(:active_path=)

          @model.active_path = Array(path)
          true
        rescue StandardError => e
          log("active path set failed: #{e.class}: #{e.message}")
          false
        end

        def matches?(path)
          current_path = @model&.active_path
          target_path = Array(path)
          return false unless current_path && current_path.length == target_path.length

          current_path.each_with_index.all? { |entity, index| entity == target_path[index] }
        rescue StandardError
          false
        end

        def normalize_for_cell_space_creation(primal_group:, edit_context:)
          return false if edit_context && !primal_group&.valid?

          target_path = edit_context && primal_group&.valid? ? [primal_group] : nil
          return true if target_path.nil? && @model&.active_path.nil?
          return true if !target_path.nil? && matches?(target_path)

          with_preserved_selection do
            target_path.nil? ? close_to_root : set(target_path)
          end
        rescue StandardError => e
          log("cell space creation active path normalize failed: #{e.class}: #{e.message}")
          false
        end

        private

        def with_preserved_selection
          selection = model_selection
          selected_entities = selection&.to_a
          result = yield
          restore_selection(selection, selected_entities) if result && selected_entities
          result
        end

        def model_selection
          return nil unless @model&.respond_to?(:selection)

          @model.selection
        rescue StandardError
          nil
        end

        def restore_selection(selection, selected_entities)
          return unless selection

          selection.clear if selection.respond_to?(:clear)
          Array(selected_entities).each do |entity|
            next if entity.respond_to?(:valid?) && !entity.valid?

            selection.add(entity) if selection.respond_to?(:add)
          end
        rescue StandardError => e
          log("selection restore failed: #{e.class}: #{e.message}")
        end

        def log(message)
          @logger.puts("[IndoorGML] #{message}") if @logger&.respond_to?(:puts)
        end
      end

    end
  end
end
