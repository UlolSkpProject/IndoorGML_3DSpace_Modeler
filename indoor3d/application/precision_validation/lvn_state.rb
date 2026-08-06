# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        module LvnState
          DICTIONARY_NAME = 'IndoorGml'
          FAILED_KEY = 'lvn_failed'

          module_function

          def group_for(candidate)
            return candidate.valid_sketchup_group if candidate.respond_to?(:valid_sketchup_group)
            return candidate.sketchup_group if candidate.respond_to?(:sketchup_group)

            candidate
          rescue StandardError
            nil
          end

          def valid_group?(group)
            return false if group.nil?
            return true unless group.respond_to?(:valid?)

            group.valid? == true
          rescue StandardError
            false
          end

          def failed?(candidate)
            group = group_for(candidate)
            return false unless valid_group?(group)

            value = group.get_attribute(DICTIONARY_NAME, FAILED_KEY, false)
            value == true || value.to_s.casecmp('true').zero?
          rescue StandardError
            false
          end

          def set_failed(candidate, failed)
            group = group_for(candidate)
            return false unless valid_group?(group)

            target = failed == true
            raw_value = group.get_attribute(DICTIONARY_NAME, FAILED_KEY)
            current = raw_value == true || raw_value.to_s.casecmp('true').zero?
            return false unless raw_value.nil? || current != target

            group.set_attribute(DICTIONARY_NAME, FAILED_KEY, target)
            true
          rescue StandardError => error
            log("LVN state write failed: #{error.class}: #{error.message}")
            false
          end

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
