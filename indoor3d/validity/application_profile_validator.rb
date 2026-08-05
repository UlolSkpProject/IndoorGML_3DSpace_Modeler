# frozen_string_literal: true

require 'rexml/document'
require 'rexml/xpath'
require_relative '../definition'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ApplicationProfileValidator
          Result = Struct.new(:valid, :errors, :profile_id, :profile_name, keyword_init: true) do
            def valid?
              valid == true
            end
          end

          CORE_NAMESPACE = 'http://www.opengis.net/indoorgml/1.0/core'
          NAVIGATION_NAMESPACE = 'http://www.opengis.net/indoorgml/1.0/navigation'
          GML_NAMESPACE = 'http://www.opengis.net/gml/3.2'
          XLINK_NAMESPACE = 'http://www.w3.org/1999/xlink'
          NAMESPACES = {
            'core' => CORE_NAMESPACE,
            'navi' => NAVIGATION_NAMESPACE,
            'gml' => GML_NAMESPACE,
            'xlink' => XLINK_NAMESPACE
          }.freeze
          ALLOWED_CELL_NAMES = %w[
            CellSpace GeneralSpace TransitionSpace ConnectionSpace AnchorSpace
          ].freeze

          def validate(path)
            document = REXML::Document.new(File.read(path, encoding: 'UTF-8'))
            errors = []
            validate_root(document, errors)
            validate_space_layers(document, errors)
            validate_cell_spaces(document, errors)
            validate_states(document, errors)
            validate_transitions(document, errors)
            validate_internal_links(document, errors)
            Result.new(
              valid: errors.empty?,
              errors: errors,
              profile_id: Definition::APPLICATION_PROFILE_ID,
              profile_name: Definition::APPLICATION_PROFILE_NAME
            )
          rescue StandardError => e
            Result.new(
              valid: false,
              errors: [profile_error('PROFILE_VALIDATOR_ERROR', e.message)],
              profile_id: Definition::APPLICATION_PROFILE_ID,
              profile_name: Definition::APPLICATION_PROFILE_NAME
            )
          end

          private

          def validate_root(document, errors)
            root = document.root
            unless root && root.name == 'IndoorFeatures' && root.namespace == CORE_NAMESPACE
              errors << profile_error(
                'PROFILE_ROOT',
                'Root element must be core:IndoorFeatures in the IndoorGML 1.0 namespace.'
              )
            end
          end

          def validate_space_layers(document, errors)
            count = xpath(document, '//core:SpaceLayer').length
            return if count == 1

            errors << profile_error(
              'PROFILE_SINGLE_SPACE_LAYER',
              "Application profile requires exactly one SpaceLayer; found #{count}."
            )
          end

          def validate_cell_spaces(document, errors)
            xpath(document, '//core:cellSpaceMember/*').each do |cell|
              unless ALLOWED_CELL_NAMES.include?(cell.name)
                errors << profile_error(
                  'PROFILE_CELL_TYPE',
                  "Unsupported CellSpace element #{cell.expanded_name}."
                )
              end
              solids = xpath(cell, './/gml:Solid')
              if solids.length != 1
                errors << profile_error(
                  'PROFILE_3D_SOLID',
                  "CellSpace #{gml_id(cell)} must contain exactly one gml:Solid."
                )
                next
              end
              unless xpath(solids.first, './gml:interior').empty?
                errors << profile_error(
                  'PROFILE_CAVITY_UNSUPPORTED',
                  "CellSpace #{gml_id(cell)} contains a Solid interior shell; cavities are unsupported."
                )
              end
            end
          end

          def validate_states(document, errors)
            xpath(document, '//core:State').each do |state|
              duality = xpath(state, './core:duality')
              points = xpath(state, './core:geometry/gml:Point')
              next if duality.length == 1 && points.length == 1

              errors << profile_error(
                'PROFILE_STATE',
                "State #{gml_id(state)} must have one duality and one gml:Point."
              )
            end
          end

          def validate_transitions(document, errors)
            xpath(document, '//core:Transition').each do |transition|
              connects = xpath(transition, './core:connects')
              hrefs = connects.map { |element| xlink_href(element) }
              positions = xpath(transition, './core:geometry/gml:LineString/gml:pos')
              valid_connects = connects.length == 2 && hrefs.none?(&:empty?) && hrefs.uniq.length == 2
              valid_positions = [2, 3].include?(positions.length)
              next if valid_connects && valid_positions

              errors << profile_error(
                'PROFILE_TRANSITION',
                "Transition #{gml_id(transition)} requires two distinct connects and a 2- or 3-point LineString."
              )
            end
          end

          def validate_internal_links(document, errors)
            ids = xpath(document, '//*[@gml:id]').map { |element| gml_id(element) }
            xpath(document, '//*[@xlink:href]').each do |element|
              href = xlink_href(element)
              next if href.start_with?('#') && ids.include?(href.delete_prefix('#'))

              errors << profile_error(
                'PROFILE_INTERNAL_XLINK',
                "Profile requires resolved internal XLinks; found #{href.inspect}."
              )
            end
          end

          def xpath(node, path)
            REXML::XPath.match(node, path, NAMESPACES)
          end

          def gml_id(element)
            element.attributes.get_attribute_ns(GML_NAMESPACE, 'id')&.value.to_s
          end

          def xlink_href(element)
            element.attributes.get_attribute_ns(XLINK_NAMESPACE, 'href')&.value.to_s
          end

          def profile_error(code, description)
            { 'code' => code, 'description' => description.to_s }
          end
        end
      end
    end
  end
end
