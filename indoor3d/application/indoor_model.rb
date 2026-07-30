# frozen_string_literal: true

require_relative '../definition'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class IndoorModel
        PRIMAL_GROUP_NAME = 'IndoorGML_PrimalSpaceFeatures'
        PRIMAL_GROUP_FEATURE = 'primalspace'
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml'

        require_relative 'cell_space_lifecycle_service'
        require_relative 'cell_space_conversion'
        require_relative 'topology_coordinator'
        require_relative 'indoor_model/runtime_support.rb'
        require_relative 'indoor_model/scene_groups.rb'
        require_relative 'indoor_model/feature_lifecycle.rb'
        require_relative 'indoor_model/topology.rb'
        require_relative 'indoor_model/observer_routing.rb'
        require_relative 'indoor_model/entity_relocation.rb'
        require_relative 'indoor_model/primal_normalization.rb'
        require_relative 'indoor_model/local_vertex_normalization.rb'
        require_relative 'indoor_model/local_grid_coordinate_v2.rb'
        require_relative 'indoor_model/local_grid_geometry_close_v2.rb'
        require_relative 'indoor_model/local_grid_runtime_dispatch_v2.rb'
        require_relative 'indoor_model/editor_control.rb'
        require_relative 'indoor_model/cell_space_batch_lifecycle.rb'
        require_relative 'indoor_model/cell_space_batch_execution.rb'
        require_relative 'indoor_model/cell_space_batch_compatibility.rb'
        require_relative 'indoor_model/ui_feedback.rb'

        include RuntimeSupport
        include SceneGroups
        include FeatureLifecycle
        include Topology
        include ObserverRouting
        include EntityRelocation
        include PrimalNormalization
        include LocalVertexNormalization
        include LocalGridCoordinateV2
        include EditorControl
        include CellSpaceBatchLifecycle
        include CellSpaceBatchExecution
        include CellSpaceBatchCompatibility
        include UiFeedbackIntegration

        attr_reader :cell_spaces
        attr_reader :states
        attr_reader :transitions
        attr_reader :model
        attr_reader :primal_group
        attr_reader :editor_session

        def self.for(model = Sketchup.active_model)
          @instances ||= {}
          key = model ? model.object_id : :active_model
          @instances[key] ||= new(model)
        end

        def self.release(model)
          return unless model

          IndoorGmlConverter::ValidationSession.cancel_for_model(model, reason: :model_closed) if defined?(IndoorGmlConverter::ValidationSession)
          instance = @instances&.delete(model.object_id)
          instance&.cleanup_for_model_close
        end

        def self.current
          self.for(Sketchup.active_model)
        end

        def self.each_instance
          @instances&.each_value || []
        end

        def cleanup_for_model_close
          IndoorGmlConverter::Val3dityRunner.terminate_for_model(@model, wait_ms: 0)
          @editor_session.close_dialog_only()
          detach_edit_selection_observer(@model)
          clear_transaction_replay! if respond_to?(:clear_transaction_replay!)
          reset_runtime_collections
          @cell_space_observed_ids.clear
          @space_features_observed_ids.clear
          @selection_observed_model_id = nil
          @entities_observed_ids.clear
          @primal_group = nil
          @model = nil
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] IndoorModel close cleanup failed: #{e.class}: #{e.message}"
        end

        def initialize(model = Sketchup.active_model)
          @model = model || Sketchup.active_model
          @feature_registry = FeatureRegistry.new
          bind_registry_collections
          @cell_space_observer = CellSpaceObserver.new(self)
          @space_features_observer = SpaceFeaturesObserver.new(self)
          @root_entities_observer = Indoor3DGmlRootEntitiesObserver.new(self)
          @primal_entities_observer = Indoor3DGmlPrimalEntitiesObserver.new(self)
          @selection_observer = Indoor3DGmlSelectionObserver.new(self)
          @scene_group_guard = SceneGroupGuard.new
          @cell_space_change_snapshots = {}
          @space_features_change_snapshots = {}
          @cell_space_observed_ids = {}
          @space_features_observed_ids = {}
          @entities_observed_ids = {}
          @selection_observed_model_id = nil
          @attribute_serializer = AttributeSerializer.new
          @runtime_restorer = RuntimeRestorer.new(self)
          @adjacency_service = AdjacencyService.new(self)
          @editor_session = EditorSession.new(self)
          @primal_group = nil
          attach_edit_selection_observer(@model)
        end
      end
    end
  end
end
