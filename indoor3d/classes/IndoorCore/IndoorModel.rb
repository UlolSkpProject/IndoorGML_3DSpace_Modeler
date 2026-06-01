# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class IndoorModel
        PRIMAL_GROUP_NAME = 'IndoorGML_PrimalSpaceFeatures'
        DUAL_GROUP_NAME = 'IndoorGML_DualSpaceFeatures'
        PRIMAL_GROUP_FEATURE = 'primalspace'
        DUAL_GROUP_FEATURE = 'dualspace'
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml'
        INDOOR_GML_VERSION = '1.1'

        require_relative 'services/indoor_model/runtime_support.rb'
        require_relative 'services/indoor_model/scene_groups.rb'
        require_relative 'services/indoor_model/feature_lifecycle.rb'
        require_relative 'services/indoor_model/topology.rb'
        require_relative 'services/indoor_model/observer_routing.rb'
        require_relative 'services/indoor_model/entity_relocation.rb'
        require_relative 'services/indoor_model/editor_control.rb'

        include RuntimeSupport
        include SceneGroups
        include FeatureLifecycle
        include Topology
        include ObserverRouting
        include EntityRelocation
        include EditorControl

        attr_reader :cell_spaces
        attr_reader :states
        attr_reader :transitions
        attr_reader :doors
        attr_reader :transfer_spaces
        attr_reader :model
        attr_reader :primal_group
        attr_reader :dual_group
        attr_reader :editor_session
        attr_reader :overlay_min_radius_pixels
        attr_reader :overlay_max_radius_pixels

        def self.current
          @current ||= new
        end

        def initialize
          @model = Sketchup.active_model
          @feature_registry = FeatureRegistry.new
          bind_registry_collections
          @cell_space_observer = CellSpaceObserver.new(self)
          @state_observer = StateObserver.new(self)
          @space_features_observer = SpaceFeaturesObserver.new(self)
          @root_entities_observer = Indoor3DGmlRootEntitiesObserver.new(self)
          @primal_entities_observer = Indoor3DGmlPrimalEntitiesObserver.new(self)
          @dual_entities_observer = Indoor3DGmlDualEntitiesObserver.new(self)
          @selection_observer = Indoor3DGmlSelectionObserver.new(self)
          @cell_space_observed_ids = {}
          @state_observed_ids = {}
          @space_features_observed_ids = {}
          @selection_observed_model_id = nil
          @entities_observed_ids = {}
          @syncing = false
          @erasing = false
          @relocating_entity = false
          @refreshing_runtime = false
          @constraining_space_features = false
          @overlay_min_radius_pixels = 14.0
          @overlay_max_radius_pixels = 64.0
          @primal_group = nil
          @dual_group = nil
          @attribute_serializer = AttributeSerializer.new(
            dictionary_name: ATTRIBUTE_DICTIONARY_NAME,
            indoor_gml_version: INDOOR_GML_VERSION
          )
          @adjacency_service = AdjacencyService.new(
            @feature_registry,
            transition_builder: method(:create_or_update_transition_for_pair),
            transition_eraser: method(:erase_transition_for_pair_key)
          )
          @runtime_restorer = RuntimeRestorer.new(
            @feature_registry,
            @attribute_serializer,
            cell_space_registrar: method(:register_cell_space),
            state_registrar: method(:register_state)
          )
          @scene_group_guard = SceneGroupGuard.new(with_unlocked: method(:with_unlocked))
          @editor_session = EditorSession.new(self)
        end
      end

    end
  end
end
