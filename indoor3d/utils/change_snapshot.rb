# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module ChangeSnapshot
        def self.field_changed?(key, previous_value, current_value)
          if key == :transformation
            return true if previous_value.nil? || current_value.nil?

            previous_value.each_with_index.any? do |value, index|
              (value - current_value[index]).abs > 0.000001
            end
          else
            previous_value != current_value
          end
        end

        def self.log_value(value)
          return 'nil' if value.nil?
          return transform_log_value(value) if value.is_a?(Array) && value.length == 16

          value.inspect
        end

        def self.transform_log_value(values)
          translation = values.values_at(12, 13, 14).map { |value| format('%.6f', value) }
          axes = values.values_at(0, 5, 10).map { |value| format('%.6f', value) }
          "translation=[#{translation.join(',')}] axes_diag=[#{axes.join(',')}]"
        end
      end
    end
  end
end
