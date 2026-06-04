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
        
      end
    end
  end
end