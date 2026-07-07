# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        LEVELS = {
          debug: 0,
          info: 1,
          warn: 2,
          error: 3,
          silent: 4
        }.freeze

        DEFAULT_LEVEL = :debug

        def self.level
          @level ||= DEFAULT_LEVEL
        end

        def self.level=(value)
          normalized = value.to_sym
          @level = LEVELS.key?(normalized) ? normalized : DEFAULT_LEVEL
        end

        def self.debug(message = nil, &block)
          log(:debug, message, &block)
        end

        def self.info(message = nil, &block)
          log(:info, message, &block)
        end

        def self.warn(message = nil, &block)
          log(:warn, message, &block)
        end

        def self.error(message = nil, &block)
          log(:error, message, &block)
        end

        def self.puts(message = nil, &block)
          info(message, &block)
        end

        def self.log(level_name, message = nil)
          return unless enabled?(level_name)

          resolved = block_given? ? yield : message
          Kernel.puts(resolved) unless resolved.nil?
        end

        def self.enabled?(level_name)
          LEVELS.fetch(level_name, LEVELS[:info]) >= LEVELS.fetch(level, LEVELS[DEFAULT_LEVEL])
        end
      end
    end
  end
end
