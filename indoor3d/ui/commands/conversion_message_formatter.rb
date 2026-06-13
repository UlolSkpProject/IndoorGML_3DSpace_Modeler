# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ConversionMessageFormatter
        def self.group_label(group)
          name = group.respond_to?(:name) ? group.name.to_s.strip : ''
          id = group.respond_to?(:entityID) ? group.entityID : nil
          return "#{name} (entity #{id})" unless name.empty? || id.nil?
          return name unless name.empty?
          return "entity #{id}" unless id.nil?

          'unknown group'
        end

        def self.result_message(converted_count, errors)
          message = +"Succeed : #{converted_count}\nFailed : #{errors.length}"
          return message if errors.empty?

          grouped_errors = errors.group_by { |error| reason_label(error[:reason]) }
          grouped_errors.each do |reason, entries|
            message << "\n- #{reason}"
            entries.each do |entry|
              message << "\n  #{entry[:group]}"
            end
          end
          message
        end

        def self.reason_label(reason)
          return 'SolidGroup내 분리된 형상' if reason.to_s.include?('Disconnected solid shells detected')

          reason.to_s.empty? ? '알 수 없는 실패 원인' : reason.to_s
        end
      end
    end
  end
end
