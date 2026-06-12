# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ObserverHelpers

        def indoor_feature(entity)
          entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
        rescue StandardError
          nil
        end
      
        def indoor_gml_entity?(entity)
          indoor_feature(entity).to_s.length.positive?
        end
      
        def entity_name(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          name.empty? ? '(unnamed)' : name
        end

        def entity_summary(entity)
          "class=#{entity.class} entity_id=#{entity.entityID} name=#{entity_name(entity)} feature=#{indoor_feature(entity)}"
        rescue StandardError
          "class=#{entity.class}"
        end

        def log_event(event_name, entity)
          IndoorCore::Logger.puts "[IndoorGML] #{self.class.name.split('::').last}##{event_name} #{entity_summary(entity)}"
        end
        
        def log_removed(event_name, entity_id)
          IndoorCore::Logger.puts "[IndoorGML] #{self.class.name.split('::').last}##{event_name} entity_id=#{entity_id}"
        end

      end
    end
  end
end
