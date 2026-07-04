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
          IndoorCore::Logger.puts "[IndoorGML] #{self.class.name.split('::').last}##{event_name} #{entity_summary(entity)}#{observer_replay_context(entity)}"
        end
        
        def log_removed(event_name, entity_id)
          IndoorCore::Logger.puts "[IndoorGML] #{self.class.name.split('::').last}##{event_name} entity_id=#{entity_id}#{observer_replay_context}"
        end

        def observer_replay_context(entity = nil)
          return '' unless instance_variable_defined?(:@indoor_model)

          indoor_model = instance_variable_get(:@indoor_model)
          return '' unless indoor_model

          diagnostic = indoor_model.respond_to?(:diagnostic_snapshot) ? indoor_model.diagnostic_snapshot : {}
          replay_pending = indoor_model.respond_to?(:transaction_replay_pending?) && indoor_model.transaction_replay_pending?
          replay_source = indoor_model.respond_to?(:transaction_replay_source) ? indoor_model.transaction_replay_source : nil
          replay_generation = indoor_model.respond_to?(:transaction_replay_generation) ? indoor_model.transaction_replay_generation : nil
          persistent_id = entity.respond_to?(:persistent_id) ? entity.persistent_id : nil
          " persistent_id=#{persistent_id || 'n/a'} replay_pending=#{replay_pending} replay_source=#{replay_source || 'n/a'} replay_generation=#{replay_generation || 'n/a'} active_path=#{diagnostic[:active_path] || 'n/a'} dirty_queue=#{diagnostic[:dirty_topology_count].to_i}"
        rescue StandardError
          ''
        end

      end
    end
  end
end
