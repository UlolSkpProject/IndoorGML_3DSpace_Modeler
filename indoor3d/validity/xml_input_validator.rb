# frozen_string_literal: true

require 'rexml/document'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class XmlInputValidator
          Result = Struct.new(:valid, :errors, keyword_init: true) do
            def valid?
              valid == true
            end
          end

          FORBIDDEN_DOCTYPE = /<!DOCTYPE/i

          def validate(path)
            content = File.binread(path)
            return invalid_result('DOCTYPE declarations are not permitted.') if content.match?(FORBIDDEN_DOCTYPE)

            text = content.dup.force_encoding(Encoding::UTF_8)
            return invalid_result('Input is not valid UTF-8.') unless text.valid_encoding?

            document = REXML::Document.new(text)
            return invalid_result('Input XML has no document element.') unless document.root

            Result.new(valid: true, errors: [])
          rescue REXML::ParseException => e
            Result.new(
              valid: false,
              errors: [
                {
                  'code' => 'XML_NOT_WELL_FORMED',
                  'description' => e.message.to_s.lines.first.to_s.strip,
                  'line' => parse_error_value(e, :line),
                  'column' => parse_error_value(e, :position)
                }.compact
              ]
            )
          rescue StandardError => e
            invalid_result("Input parsing failed: #{e.message}")
          end

          private

          def invalid_result(message)
            Result.new(
              valid: false,
              errors: [{ 'code' => 'XML_INPUT_ERROR', 'description' => message.to_s }]
            )
          end

          def parse_error_value(error, method_name)
            return nil unless error.respond_to?(method_name)

            value = error.public_send(method_name)
            value.to_i.positive? ? value.to_i : nil
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
