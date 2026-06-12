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

        def self.debug(message)
          log(:debug, message)
        end

        def self.info(message)
          log(:info, message)
        end

        def self.warn(message)
          log(:warn, message)
        end

        def self.error(message)
          log(:error, message)
        end

        def self.puts(message)
          info(message)
        end

        def self.log(level_name, message)
          return unless enabled?(level_name)

          Kernel.puts(message)
        end

        def self.enabled?(level_name)
          LEVELS.fetch(level_name, LEVELS[:info]) >= LEVELS.fetch(level, LEVELS[DEFAULT_LEVEL])
        end
      end
    end
  end
end
