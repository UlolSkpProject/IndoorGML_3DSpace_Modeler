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

        private

        def log(message)
          @logger.puts("[IndoorGML] #{message}") if @logger&.respond_to?(:puts)
        end
      end

    end
  end
end
