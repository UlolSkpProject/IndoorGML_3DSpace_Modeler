# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class EntityObserver; end unless const_defined?(:EntityObserver)
  class EntitiesObserver; end unless const_defined?(:EntitiesObserver)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.debug
          yield if block_given?
        end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/infrastructure/observers/observer_helpers'
require_relative '../indoor3d/infrastructure/observers/space_features_observer'
require_relative '../indoor3d/infrastructure/observers/root_entities_observer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class SpaceFeaturesEraseObserversTest < Minitest::Test
        def test_space_features_erase_does_not_depend_on_erased_entity_attributes
          model = FakeIndoorModel.new
          entity = ErasedEntity.new(101)
          observer = SpaceFeaturesObserver.new(model)

          observer.onEraseEntity(entity)

          assert_equal [entity], model.space_features_erased_entities
        end

        def test_root_entities_removal_uses_tracked_primal_entity_id_as_fallback
          model = FakeIndoorModel.new
          entity = ErasedEntity.new(101)
          observer = Indoor3DGmlRootEntitiesObserver.new(model)
          observer.track_entity(entity)

          observer.onElementRemoved(nil, 101)
          observer.onElementRemoved(nil, 101)

          assert_equal [101], model.root_removed_ids
        end

        class FakeIndoorModel
          attr_reader :space_features_erased_entities, :root_removed_ids

          def initialize
            @space_features_erased_entities = []
            @root_removed_ids = []
          end

          def space_features_erased(entity)
            @space_features_erased_entities << entity
          end

          def root_entity_removed(entity_id)
            @root_removed_ids << entity_id
          end
        end

        class ErasedEntity
          attr_reader :entityID

          def initialize(entity_id)
            @entityID = entity_id
          end

          def get_attribute(*)
            raise 'attributes unavailable after erase'
          end

          def persistent_id
            entityID
          end

          def name
            'erased primal group'
          end
        end
      end
    end
  end
end
