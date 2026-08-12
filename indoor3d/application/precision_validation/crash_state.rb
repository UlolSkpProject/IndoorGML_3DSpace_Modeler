# frozen_string_literal: true

require_relative 'lvn_state'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        module CrashState
          DICTIONARY_NAME = LvnState::DICTIONARY_NAME
          STATUS_KEY = 'precision_crash_status'
          CHECKED_KEY = 'precision_crash_checked'
          CRASHED_KEY = 'precision_crash_detected'
          UNKNOWN = 'unknown'
          PASSED = 'passed'
          CRASHED = 'crashed'
          STATUSES = [UNKNOWN, PASSED, CRASHED].freeze

          module_function

          def checked?(candidate)
            status(candidate) != UNKNOWN
          end

          def crashed?(candidate)
            status(candidate) == CRASHED
          end

          def status(candidate)
            group = LvnState.group_for(candidate)
            return UNKNOWN unless LvnState.valid_group?(group)

            value = group.get_attribute(DICTIONARY_NAME, STATUS_KEY, nil).to_s
            return value if STATUSES.include?(value)

            # Read the two legacy Boolean attributes so models marked by an
            # earlier build keep their cached crash result.
            return UNKNOWN unless truthy_attribute?(group, CHECKED_KEY)

            truthy_attribute?(group, CRASHED_KEY) ? CRASHED : PASSED
          rescue StandardError
            UNKNOWN
          end

          def set(candidate, crashed:)
            group = LvnState.group_for(candidate)
            return false unless LvnState.valid_group?(group)

            target_crashed = crashed == true
            changed = write_attribute(group, STATUS_KEY, target_crashed ? CRASHED : PASSED)
            changed = write_attribute(group, CHECKED_KEY, true) || changed
            changed = write_attribute(group, CRASHED_KEY, target_crashed) || changed
            changed
          rescue StandardError => error
            log("Crash state write failed: #{error.class}: #{error.message}")
            false
          end

          def clear(candidate)
            group = LvnState.group_for(candidate)
            return false unless LvnState.valid_group?(group)

            changed = write_attribute(group, STATUS_KEY, UNKNOWN)
            changed = write_attribute(group, CHECKED_KEY, false) || changed
            changed = write_attribute(group, CRASHED_KEY, false) || changed
            changed
          rescue StandardError => error
            log("Crash state clear failed: #{error.class}: #{error.message}")
            false
          end

          def truthy_attribute?(candidate, key)
            group = LvnState.group_for(candidate)
            return false unless LvnState.valid_group?(group)

            value = group.get_attribute(DICTIONARY_NAME, key, false)
            value == true || value.to_s.casecmp('true').zero?
          rescue StandardError
            false
          end
          private_class_method :truthy_attribute?

          def write_attribute(group, key, value)
            current = group.get_attribute(DICTIONARY_NAME, key, nil)
            return false if current == value

            group.set_attribute(DICTIONARY_NAME, key, value)
            true
          end
          private_class_method :write_attribute

          def log(message)
            return unless defined?(IndoorCore::Logger)
            return unless IndoorCore::Logger.respond_to?(:puts)

            IndoorCore::Logger.puts("[IndoorGML] #{message}")
          rescue StandardError
            nil
          end
          private_class_method :log
        end
      end
    end
  end
end
