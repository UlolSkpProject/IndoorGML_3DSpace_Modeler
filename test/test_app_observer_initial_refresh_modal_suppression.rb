# frozen_string_literal: true

require 'minitest/autorun'

module UI
  class << self
    attr_accessor :app_observer_timers, :messagebox_calls
  end

  def self.start_timer(_delay, _repeat = false, &block)
    self.app_observer_timers ||= []
    app_observer_timers << block
    app_observer_timers.length
  end

  def self.messagebox(message, *arguments)
    self.messagebox_calls ||= []
    messagebox_calls << [message, arguments]
    :shown
  end
end

module Sketchup
  class AppObserver; end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      module UiFeedback
        class << self
          attr_accessor :app_observer_suppression_reasons
        end

        def self.with_modal_suppressed(reason: nil)
          self.app_observer_suppression_reasons ||= []
          app_observer_suppression_reasons << reason
          yield
        end
      end

      class Indoor3DGmlModelObserver
        def initialize(on_delete_model: nil)
          @on_delete_model = on_delete_model
        end

        def forget_model(_model); end
      end

      class IndoorModel
        PRIMAL_GROUP_NAME = 'IndoorGML_PrimalSpaceFeatures' unless const_defined?(:PRIMAL_GROUP_NAME)
        PRIMAL_GROUP_FEATURE = 'primalspace' unless const_defined?(:PRIMAL_GROUP_FEATURE)
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml' unless const_defined?(:ATTRIBUTE_DICTIONARY_NAME)

        def self.for(model)
          model.indoor_model
        end

        def self.release(_model); end
      end
    end
  end
end

require_relative '../indoor3d/infrastructure/observers/app_observer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AppObserverInitialRefreshModalSuppressionTest < Minitest::Test
        class FakeEntities
          def initialize(items = [])
            @items = items
          end

          def to_a
            @items.dup
          end
        end

        class FakeEntity
          attr_reader :name, :entities

          def initialize(name: '', feature: nil, children: [])
            @name = name
            @feature = feature
            @entities = FakeEntities.new(children)
          end

          def valid?
            true
          end

          def get_attribute(dictionary, key)
            return nil unless dictionary == IndoorModel::ATTRIBUTE_DICTIONARY_NAME
            return @feature if key == 'feature'

            nil
          end
        end

        class FakeIndoorModel
          attr_reader :refresh_calls

          def initialize
            @refresh_calls = []
          end

          def refresh_runtime_data(initial_model_load: false)
            @refresh_calls << initial_model_load
            true
          end
        end

        class FakeModel
          attr_reader :indoor_model, :observers, :entities

          def initialize(root_entities = [])
            @indoor_model = FakeIndoorModel.new
            @observers = []
            @entities = FakeEntities.new(root_entities)
          end

          def add_observer(observer)
            @observers << observer
            true
          end

          def remove_observer(observer)
            @observers.delete(observer)
            true
          end
        end

        def setup
          UI.app_observer_timers = []
          UI.messagebox_calls = []
          UiFeedback.app_observer_suppression_reasons = []
        end

        def test_initial_refresh_runs_only_for_primal_with_persisted_cell_space
          model = model_with_persisted_cell_space
          observer = Indoor3DGmlAppObserver.new

          assert observer.schedule_initial_refresh(model)
          assert_equal 1, UI.app_observer_timers.length

          UI.app_observer_timers.shift.call

          assert_equal [:initial_runtime_refresh],
                       UiFeedback.app_observer_suppression_reasons
          assert_equal [true], model.indoor_model.refresh_calls
        end

        def test_model_without_primal_skips_initial_refresh
          model = FakeModel.new
          observer = Indoor3DGmlAppObserver.new

          assert observer.schedule_initial_refresh(model)
          UI.app_observer_timers.shift.call

          assert_empty model.indoor_model.refresh_calls
          assert_empty UiFeedback.app_observer_suppression_reasons
        end

        def test_primal_without_cell_space_skips_initial_refresh
          primal = FakeEntity.new(
            name: IndoorModel::PRIMAL_GROUP_NAME,
            feature: IndoorModel::PRIMAL_GROUP_FEATURE
          )
          model = FakeModel.new([primal])
          observer = Indoor3DGmlAppObserver.new

          assert observer.schedule_initial_refresh(model)
          UI.app_observer_timers.shift.call

          assert_empty model.indoor_model.refresh_calls
        end

        def test_tag_only_group_is_not_treated_as_persisted_cell_space
          tag_only_group = FakeEntity.new(name: 'F01F01_IP_RM_23')
          primal = FakeEntity.new(
            name: IndoorModel::PRIMAL_GROUP_NAME,
            feature: IndoorModel::PRIMAL_GROUP_FEATURE,
            children: [tag_only_group]
          )
          model = FakeModel.new([primal])
          observer = Indoor3DGmlAppObserver.new

          assert observer.schedule_initial_refresh(model)
          UI.app_observer_timers.shift.call

          assert_empty model.indoor_model.refresh_calls
        end

        def test_nested_persisted_cell_space_is_detected
          cell = FakeEntity.new(feature: 'CellSpace')
          container = FakeEntity.new(children: [cell])
          primal = FakeEntity.new(
            name: IndoorModel::PRIMAL_GROUP_NAME,
            feature: IndoorModel::PRIMAL_GROUP_FEATURE,
            children: [container]
          )
          model = FakeModel.new([primal])
          observer = Indoor3DGmlAppObserver.new

          assert observer.schedule_initial_refresh(model)
          UI.app_observer_timers.shift.call

          assert_equal [true], model.indoor_model.refresh_calls
        end

        def test_messageboxes_are_not_globally_intercepted
          message =
            "IndoorGML initial runtime load\n\n0.003 s\n\ncells=0\nstates=0\ntransitions=0"
          result = UI.messagebox(
            message
          )

          assert_equal :shown, result
          assert_equal [[message, []]], UI.messagebox_calls
        end

        def test_other_messageboxes_are_not_suppressed
          assert_equal :shown, UI.messagebox('Other application message')
          assert_equal [['Other application message', []]], UI.messagebox_calls
        end

        def test_open_model_registers_and_schedules_refresh
          model = model_with_persisted_cell_space
          observer = Indoor3DGmlAppObserver.new

          observer.onOpenModel(model)

          assert_equal 1, model.observers.length
          assert_equal 1, UI.app_observer_timers.length
        end

        private

        def model_with_persisted_cell_space
          cell = FakeEntity.new(feature: 'CellSpace')
          primal = FakeEntity.new(
            name: IndoorModel::PRIMAL_GROUP_NAME,
            feature: IndoorModel::PRIMAL_GROUP_FEATURE,
            children: [cell]
          )
          FakeModel.new([primal])
        end
      end
    end
  end
end
