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
          assert_equal [[:undo, 1], [:redo, 2]], model.runtime.replay_begins
          assert_equal [2], model.runtime.replay_finishes
          assert_equal false, model.runtime.transaction_replay_pending?
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
          assert_equal false, model_a.runtime.transaction_replay_pending?
          assert_equal false, model_b.runtime.transaction_replay_pending?
        end

        def test_undo_redo_undo_runs_only_latest_generation
          observer = Indoor3DGmlModelObserver.new
          model = FakeModel.new

          observer.onTransactionUndo(model)
          observer.onTransactionRedo(model)
          observer.onTransactionUndo(model)
          UI.timers.each { |timer| timer[:block].call }

          assert_equal [[:undo, 3]], model.runtime.reconciliations
          assert_equal [3], model.runtime.replay_finishes
        end

        def test_forget_model_cancels_pending_generation
          observer = Indoor3DGmlModelObserver.new
          model = FakeModel.new

          observer.onTransactionUndo(model)
          observer.forget_model(model)
          UI.timers.first[:block].call

          assert_empty model.runtime.reconciliations
        end

        def test_reconciliation_exception_still_finishes_replay
          observer = Indoor3DGmlModelObserver.new
          model = FakeModel.new
          model.runtime.raise_on_reconcile = true

          observer.onTransactionUndo(model)
          UI.timers.first[:block].call

          assert_equal [[:undo, 1]], model.runtime.reconciliations
          assert_equal [1], model.runtime.replay_finishes
          assert_equal false, model.runtime.transaction_replay_pending?
        end

        def test_transaction_replay_path_is_read_only
          observer = Indoor3DGmlModelObserver.new
          model = SpyModel.new

          observer.onTransactionUndo(model)
          UI.timers.first[:block].call

          assert_equal [[:undo, 1]], model.runtime.reconciliations
          assert_equal [[:reconcile_after_transaction, :undo]], model.runtime.editor_session.calls
          assert_empty model.write_calls
          assert_empty model.spy_entity.write_calls
        end

        class FakeRuntime
          attr_accessor :raise_on_reconcile
          attr_reader :reconciliations, :active_path_sources, :replay_begins, :replay_finishes

          def initialize
            @reconciliations = []
            @active_path_sources = []
            @replay_begins = []
            @replay_finishes = []
            @replay_pending = false
          end

          def reconcile_runtime_after_transaction(source:, generation:)
            @reconciliations << [source, generation]
            raise 'reconcile failed' if @raise_on_reconcile
          end

          def active_path_changed(_model)
            @active_path_sources << :changed
          end

          def begin_transaction_replay(source:, generation:)
            @replay_pending = true
            @replay_begins << [source, generation]
          end

          def finish_transaction_replay(generation:)
            @replay_finishes << generation
            @replay_pending = false
          end

          def transaction_replay_pending?
            @replay_pending == true
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

        class SpyRuntime < FakeRuntime
          attr_reader :editor_session

          def initialize(model)
            super()
            @model = model
            @editor_session = SpyEditorSession.new
          end

          def reconcile_runtime_after_transaction(source:, generation:)
            super
            @editor_session.reconcile_after_transaction(@model, source: source)
          end
        end

        class SpyEditorSession
          attr_reader :calls

          def initialize
            @calls = []
          end

          def reconcile_after_transaction(model, source: nil)
            @calls << [:reconcile_after_transaction, source]
            model.active_view.invalidate
            true
          end
        end

        class SpyModel
          attr_reader :runtime, :write_calls, :spy_entity, :active_view

          def initialize
            @write_calls = []
            @spy_entity = SpyEntity.new
            @runtime = SpyRuntime.new(self)
            @active_view = SpyView.new
            @active_path = [@spy_entity]
          end

          def active_path
            @active_path
          end

          def active_path=(value)
            @write_calls << [:active_path=, value]
            @active_path = value
          end

          def close_active
            @write_calls << :close_active
            @active_path = nil
          end

          def start_operation(*)
            @write_calls << :start_operation
            true
          end

          def commit_operation
            @write_calls << :commit_operation
            true
          end

          def abort_operation
            @write_calls << :abort_operation
            true
          end
        end

        class SpyEntity
          attr_reader :write_calls

          def initialize
            @write_calls = []
          end

          def valid?
            true
          end

          def persistent_id
            42
          end

          def locked=(value)
            @write_calls << [:locked=, value]
          end

          def hidden=(value)
            @write_calls << [:hidden=, value]
          end

          def visible=(value)
            @write_calls << [:visible=, value]
          end

          def set_attribute(*args)
            @write_calls << [:set_attribute, args]
          end

          def erase!
            @write_calls << :erase!
          end

          def transform!(*args)
            @write_calls << [:transform!, args]
          end
        end

        class SpyView
          attr_reader :invalidations

          def initialize
            @invalidations = 0
          end

          def invalidate
            @invalidations += 1
          end
        end
      end
    end
  end
end
