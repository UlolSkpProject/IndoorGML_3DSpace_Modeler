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
        require_relative 'indoor_model/runtime_support.rb'
        require_relative 'indoor_model/scene_groups.rb'
        require_relative 'indoor_model/feature_lifecycle.rb'
        require_relative 'indoor_model/topology.rb'
        require_relative 'indoor_model/observer_routing.rb'
        require_relative 'indoor_model/entity_relocation.rb'
        require_relative 'indoor_model/primal_normalization.rb'
        require_relative 'indoor_model/editor_control.rb'

        include RuntimeSupport
        include SceneGroups
        include FeatureLifecycle
        include Topology
        include ObserverRouting
        include EntityRelocation
        include PrimalNormalization
        include EditorControl

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
          @cell_space_observed_ids = {}
          @cell_space_change_snapshots = {}
          @dirty_cell_space_pids = {}
          @cell_space_sync_scheduled = false
          @space_features_observed_ids = {}
          @space_features_change_snapshots = {}
          @selection_observed_model_id = nil
          @entities_observed_ids = {}
          @syncing = false
          @erasing = false
          @relocating_entity = false
          @refreshing_runtime = false
          @transaction_replay_pending = false
          @transaction_replay_source = nil
          @transaction_replay_generation = nil
          @constraining_space_features = false
          @primal_group = nil
          @attribute_serializer = AttributeSerializer.new(
            dictionary_name: ATTRIBUTE_DICTIONARY_NAME,
            indoor_gml_version: Definition::INDOOR_GML_VERSION
          )
          @adjacency_service = AdjacencyService.new(
            @feature_registry,
            transition_builder: method(:create_or_update_transition_for_pair),
            transition_eraser: method(:erase_transition_for_pair_key)
          )
          @runtime_restorer = RuntimeRestorer.new(
            registry: @feature_registry,
            serializer: @attribute_serializer,
            cell_space_registrar: method(:register_cell_space),
            state_registrar: method(:register_state)
          )
          @scene_group_guard = SceneGroupGuard.new(
            with_unlocked: method(:with_unlocked),
            notifier: method(:defer_ui_message)
          )
          @editor_session = EditorSession.new(self)
          @finishing_editing = false
        end
      end

    end
  end
end
