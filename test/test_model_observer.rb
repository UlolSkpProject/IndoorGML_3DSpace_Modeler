# frozen_string_literal: true

require 'minitest/autorun'

module UI
  class << self
    attr_accessor :timers
  end

  def self.start_timer(interval, repeat, &block)
    self.timers ||= []
    timers << { interval: interval, repeat: repeat, block: block }
    true
  end
end

module Sketchup
  class ModelObserver; end unless const_defined?(:ModelObserver, false)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)

      class IndoorModel; end unless const_defined?(:IndoorModel)
    end
  end
end

require_relative '../indoor3d/infrastructure/observers/model_observer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ModelObserverTest < Minitest::Test
        def setup
          UI.timers = []
          @original_for = IndoorModel.method(:for) if IndoorModel.respond_to?(:for)
          IndoorModel.define_singleton_method(:for) { |model| model.runtime }
        end

        def teardown
          if @original_for
            original_for = @original_for
            IndoorModel.define_singleton_method(:for) { |model| original_for.call(model) }
          else
            IndoorModel.singleton_class.remove_method(:for) if IndoorModel.respond_to?(:for)
          end
          UI.timers = []
        end

        def test_undo_and_redo_schedule_reconciliation_with_source
          observer = Indoor3DGmlModelObserver.new
          model = FakeModel.new

          observer.onTransactionUndo(model)
          observer.onTransactionRedo(model)

          assert_equal 2, UI.timers.length
          UI.timers[0][:block].call
          UI.timers[1][:block].call

          assert_equal [[:redo, 2]], model.runtime.reconciliations
        end

        def test_generation_is_model_scoped
          observer = Indoor3DGmlModelObserver.new
          model_a = FakeModel.new
          model_b = FakeModel.new

          observer.onTransactionUndo(model_a)
          observer.onTransactionRedo(model_b)
          UI.timers.each { |timer| timer[:block].call }

          assert_equal [[:undo, 1]], model_a.runtime.reconciliations
          assert_equal [[:redo, 1]], model_b.runtime.reconciliations
        end

        def test_undo_redo_undo_runs_only_latest_generation
          observer = Indoor3DGmlModelObserver.new
          model = FakeModel.new

          observer.onTransactionUndo(model)
          observer.onTransactionRedo(model)
          observer.onTransactionUndo(model)
          UI.timers.each { |timer| timer[:block].call }

          assert_equal [[:undo, 3]], model.runtime.reconciliations
        end

        def test_forget_model_cancels_pending_generation
          observer = Indoor3DGmlModelObserver.new
          model = FakeModel.new

          observer.onTransactionUndo(model)
          observer.forget_model(model)
          UI.timers.first[:block].call

          assert_empty model.runtime.reconciliations
        end

        class FakeRuntime
          attr_reader :reconciliations, :active_path_sources, :recoveries

          def initialize
            @reconciliations = []
            @active_path_sources = []
            @recoveries = 0
          end

          def reconcile_runtime_after_transaction(source:, generation:)
            @reconciliations << [source, generation]
          end

          def active_path_changed(_model)
            @active_path_sources << :changed
          end

          def recover_unlocked_primal_after_transaction(_model)
            @recoveries += 1
          end
        end

        class FakeModel
          attr_accessor :active_path
          attr_reader :runtime

          def initialize(active_path = nil)
            @active_path = active_path
            @runtime = FakeRuntime.new
          end
        end
      end
    end
  end
end
