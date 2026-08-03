# frozen_string_literal: true

require 'minitest/autorun'

module UI
  class << self
    attr_accessor :app_observer_timers
  end

  def self.start_timer(_delay, _repeat = false, &block)
    self.app_observer_timers ||= []
    app_observer_timers << block
    app_observer_timers.length
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
          attr_reader :indoor_model, :observers

          def initialize
            @indoor_model = FakeIndoorModel.new
            @observers = []
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
          UiFeedback.app_observer_suppression_reasons = []
        end

        def test_initial_refresh_runs_inside_modal_suppression_scope
          model = FakeModel.new
          observer = Indoor3DGmlAppObserver.new

          assert observer.schedule_initial_refresh(model)
          assert_equal 1, UI.app_observer_timers.length

          UI.app_observer_timers.shift.call

          assert_equal [:initial_runtime_refresh],
                       UiFeedback.app_observer_suppression_reasons
          assert_equal [true], model.indoor_model.refresh_calls
        end

        def test_open_model_registers_and_schedules_refresh
          model = FakeModel.new
          observer = Indoor3DGmlAppObserver.new

          observer.onOpenModel(model)

          assert_equal 1, model.observers.length
          assert_equal 1, UI.app_observer_timers.length
        end
      end
    end
  end
end
