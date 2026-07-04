# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/application/indoor_model/observer_routing'
require_relative '../indoor3d/application/indoor_model/runtime_support'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ObserverRoutingGuardsTest < Minitest::Test
        def test_sync_guard_suppresses_entity_added_and_removed_routes
          model = FakeIndoorModel.new(syncing: true)

          model.root_entity_added(FakeEntity.new)
          model.primal_entity_added(FakeEntity.new)
          model.primal_entity_removed(123)

          assert_empty model.calls
        end

        def test_bulk_guard_suppresses_entity_added_routes
          model = FakeIndoorModel.new(bulk: true)

          model.root_entity_added(FakeEntity.new)
          model.primal_entity_added(FakeEntity.new)

          assert_empty model.calls
        end

        def test_reconciliation_guard_suppresses_space_features_changes
          model = FakeIndoorModel.new(reconciling: true)

          result = model.space_features_changed(FakeEntity.new)

          assert_equal false, result
          assert_empty model.calls
        end

        def test_suppressed_observer_context_does_not_start_nested_operation
          model = FakeOperationModel.new(syncing: true)

          result = model.run_operation

          assert_equal :ran, result
          assert_equal 0, model.sketchup_model.start_count
          assert_equal 0, model.sketchup_model.commit_count
        end

        class FakeIndoorModel
          include IndoorModel::ObserverRouting

          attr_reader :calls

          def initialize(syncing: false, bulk: false, reconciling: false)
            @syncing = syncing
            @bulk_cell_space_conversion = bulk
            @transaction_reconciliation = reconciling
            @erasing = false
            @relocating_entity = false
            @constraining_space_features = false
            @finishing_editing = false
            @calls = []
          end

          private

          def guard_active?(flag)
            instance_variable_get(flag)
          end

          def indoor_gml_entity?(_entity)
            @calls << :indoor_gml_entity?
            true
          end

          def classify_space_features_change(_entity)
            @calls << :classify_space_features_change
            :name
          end

          def with_indoor_model_operation(name, transparent: false)
            @calls << [:operation, name, transparent]
            yield
          end
        end

        class FakeOperationModel
          include IndoorModel::RuntimeSupport

          attr_reader :sketchup_model

          def initialize(syncing: false)
            @syncing = syncing
            @indoor_operation_depth = 0
            @sketchup_model = FakeSketchupModel.new
            @model = @sketchup_model
          end

          def run_operation
            send(:with_indoor_model_operation, 'Nested Observer Operation') { :ran }
          end

          def observer_routing_suppressed?
            @syncing == true
          end
        end

        class FakeSketchupModel
          attr_reader :start_count, :commit_count, :abort_count

          def initialize
            @start_count = 0
            @commit_count = 0
            @abort_count = 0
          end

          def start_operation(*)
            @start_count += 1
            true
          end

          def commit_operation
            @commit_count += 1
            true
          end

          def abort_operation
            @abort_count += 1
            true
          end
        end

        class FakeEntity
          def valid?
            true
          end
        end
      end
    end
  end
end
