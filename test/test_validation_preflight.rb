# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

require_relative '../indoor3d/validity/xml_input_validator'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ValidationPreflightTest < Minitest::Test
          FIXTURE = File.expand_path('fixtures/validation/valid_profile.gml', __dir__)

          def test_well_formed_export_passes_input_check
            assert XmlInputValidator.new.validate(FIXTURE).valid?
          end

          def test_input_parser_rejects_malformed_xml_without_claiming_xsd_validation
            with_gml('<core:IndoorFeatures>') do |path|
              result = XmlInputValidator.new.validate(path)

              refute result.valid?
              assert_equal 'XML_NOT_WELL_FORMED', result.errors.first['code']
            end
          end

          def test_input_parser_rejects_doctype
            with_gml('<!DOCTYPE root><root/>') do |path|
              result = XmlInputValidator.new.validate(path)

              refute result.valid?
              assert_equal 'XML_INPUT_ERROR', result.errors.first['code']
            end
          end

          private

          def with_gml(content)
            Dir.mktmpdir('validation-preflight-') do |directory|
              path = File.join(directory, 'input.gml')
              File.write(path, content, encoding: 'UTF-8')
              yield path
            end
          end
        end
      end
    end
  end
end
