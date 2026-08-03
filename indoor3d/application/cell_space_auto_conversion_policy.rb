# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Central policy for the outer SketchUp Tag used as CellSpace creation
      # input. A mapped Tag is consumed after its type/category/storey values
      # have been resolved; the resulting CellSpace or explicitly demoted Group
      # must live on Untagged. Legacy opt-out markers remain readable so models
      # saved by earlier builds do not regress.
      module CellSpaceAutoConversionPolicy
        DICTIONARY_NAME = 'ULOL_Indoor3D_Policy'
        AUTO_CONVERSION_DISABLED_KEY = 'cell_space_auto_conversion_disabled'
        UNASSIGNED_TAG_NAMES = ['', 'Untagged', 'Layer0'].freeze

        module_function

        def disabled?(entity)
          return false unless entity&.respond_to?(:get_attribute)

          entity.get_attribute(
            DICTIONARY_NAME,
            AUTO_CONVERSION_DISABLED_KEY,
            false
          ) == true
        rescue StandardError
          false
        end

        # Kept for compatibility with models written by the earlier marker-based
        # policy. New Create/Demotion flows consume the Tag instead of writing a
        # new marker.
        def disable!(entity)
          return false unless entity&.respond_to?(:set_attribute)

          entity.set_attribute(
            DICTIONARY_NAME,
            AUTO_CONVERSION_DISABLED_KEY,
            true
          )
          disabled?(entity)
        rescue StandardError
          false
        end

        def enable!(entity)
          return true unless entity
          return true unless entity.respond_to?(:delete_attribute)

          entity.delete_attribute(
            DICTIONARY_NAME,
            AUTO_CONVERSION_DISABLED_KEY
          )
          !disabled?(entity)
        rescue StandardError
          false
        end

        def consume_tag!(entity, model: nil)
          return false unless entity
          return false if entity.respond_to?(:valid?) && !entity.valid?
          return true unless tag_assigned?(entity)

          untagged = untagged_tag(model || entity_model(entity))
          return false unless untagged

          current = entity_tag(entity)
          unless same_tag?(current, untagged)
            if entity.respond_to?(:layer=)
              entity.layer = untagged
            elsif entity.respond_to?(:tag=)
              entity.tag = untagged
            else
              return false
            end
          end

          !tag_assigned?(entity)
        rescue StandardError
          false
        end

        def tag_assigned?(entity)
          !UNASSIGNED_TAG_NAMES.include?(tag_name(entity))
        rescue StandardError
          false
        end

        def tag_name(entity)
          tag = entity_tag(entity)
          tag.respond_to?(:name) ? tag.name.to_s : ''
        rescue StandardError
          ''
        end

        def entity_tag(entity)
          if entity&.respond_to?(:layer)
            layer = entity.layer
            return layer if layer
          end
          return entity.tag if entity&.respond_to?(:tag)

          nil
        rescue StandardError
          nil
        end
        private_class_method :entity_tag

        def entity_model(entity)
          model = entity.model if entity.respond_to?(:model)
          return model if model
          return Sketchup.active_model if defined?(Sketchup) && Sketchup.respond_to?(:active_model)

          nil
        rescue StandardError
          nil
        end
        private_class_method :entity_model

        def untagged_tag(model)
          return nil unless model

          collection = if model.respond_to?(:layers)
                         model.layers
                       elsif model.respond_to?(:tags)
                         model.tags
                       end
          return nil unless collection

          collection[0] || collection['Untagged'] || collection['Layer0']
        rescue StandardError
          nil
        end
        private_class_method :untagged_tag

        def same_tag?(first, second)
          return true if first.equal?(second)

          first_name = first.respond_to?(:name) ? first.name.to_s : ''
          second_name = second.respond_to?(:name) ? second.name.to_s : ''
          !first_name.empty? && first_name == second_name
        rescue StandardError
          false
        end
        private_class_method :same_tag?
      end
    end
  end
end
