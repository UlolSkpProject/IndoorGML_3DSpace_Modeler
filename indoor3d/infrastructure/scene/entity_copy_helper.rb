# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EntityCopyHelper
        COPYABLE_ATTRIBUTES = [:name, :material, :layer, :visible].freeze

        def self.copy_instance(source:, target_entities:, transformation:, convert_to_group: :source_group, make_unique: :source_group, copy_attributes: [], attribute_copier: nil)
          new.copy_instance(
            source: source,
            target_entities: target_entities,
            transformation: transformation,
            convert_to_group: convert_to_group,
            make_unique: make_unique,
            copy_attributes: copy_attributes,
            attribute_copier: attribute_copier
          )
        end

        def copy_instance(source:, target_entities:, transformation:, convert_to_group: :source_group, make_unique: :source_group, copy_attributes: [], attribute_copier: nil)
          validate_source!(source)
          raise ArgumentError, 'Target entities are required' unless target_entities

          copy = target_entities.add_instance(source.definition, transformation)
          raise ArgumentError, 'Could not create entity copy' unless copy&.valid?

          copy = copy.to_group if option_applies?(convert_to_group, source) && copy.respond_to?(:to_group)
          copy.make_unique if option_applies?(make_unique, source) && copy.respond_to?(:make_unique)
          copy_supported_attributes(source, copy, copy_attributes)
          attribute_copier&.call(source, copy)
          copy
        end

        private

        def validate_source!(source)
          unless source&.respond_to?(:valid?) && source.valid? && source.respond_to?(:definition) && source.definition&.valid?
            raise ArgumentError, "Unsupported entity copy source: #{source.class}"
          end
        end

        def option_applies?(option, source)
          case option
          when :source_group
            sketchup_group?(source)
          else
            option == true
          end
        end

        def sketchup_group?(source)
          defined?(Sketchup::Group) && source.is_a?(Sketchup::Group)
        end

        def copy_supported_attributes(source, copy, attributes)
          Array(attributes).each do |attribute|
            next unless COPYABLE_ATTRIBUTES.include?(attribute)

            copy_attribute(source, copy, attribute)
          end
        end

        def copy_attribute(source, copy, attribute)
          case attribute
          when :visible
            copy.visible = source.visible? if copy.respond_to?(:visible=) && source.respond_to?(:visible?)
          else
            copy.public_send("#{attribute}=", source.public_send(attribute)) if copy.respond_to?("#{attribute}=") && source.respond_to?(attribute)
          end
        end
      end
    end
  end
end
