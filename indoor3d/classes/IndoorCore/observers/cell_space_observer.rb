# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class CellSpaceObserver < Sketchup::InstanceObserver
        def initialize(indoor_model)
          super()
          @indoor_model = indoor_model
        end

        def onOpen(instance)
          return unless indoor_gml_entity?(instance)

          log_event('onOpen', instance)
        end

        def onClose(instance)
          return unless indoor_gml_entity?(instance)

          log_event('onClose', instance)
          @indoor_model.cell_space_closed(instance)
        end

        def onChangeEntity(entity)
          return unless indoor_gml_entity?(entity)

          log_event('onChangeEntity', entity)
          @indoor_model.cell_space_changed(entity)
        end

        def onEraseEntity(entity)
          return unless indoor_gml_entity?(entity)

          log_event('onEraseEntity', entity)
          @indoor_model.cell_space_erased(entity)
        end

        private

        def log_event(event_name, entity)
          puts "[IndoorGML] CellSpaceObserver##{event_name} #{entity_summary(entity)}"
        end

        def entity_summary(entity)
          begin
            "class=#{entity.class} name=#{entity_name(entity)}"
          rescue StandardError
            "class=#{entity.class}"
          end
        end

        def indoor_gml_entity?(entity)
          indoor_feature(entity).to_s.length.positive?
        end

        def indoor_feature(entity)
          begin
            entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
          rescue StandardError
            nil
          end
        end

        def entity_name(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          name.empty? ? '(unnamed)' : name
        end
      end

    end
  end
end
