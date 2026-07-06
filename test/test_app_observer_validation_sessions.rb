# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class AppObserver; end unless const_defined?(:AppObserver, false)
  class ModelObserver; end unless const_defined?(:ModelObserver, false)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)

      class Indoor3DGmlModelObserver < Sketchup::ModelObserver
        def forget_model(_model); end
      end unless const_defined?(:Indoor3DGmlModelObserver)

      class IndoorModel; end unless const_defined?(:IndoorModel)
    end
  end
end

require_relative '../indoor3d/validity/validation_session'
require_relative '../indoor3d/infrastructure/observers/app_observer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AppObserverValidationSessionsTest < Minitest::Test
        def setup
          IndoorGmlConverter::ValidationSession.reset!
          @original_for = IndoorModel.method(:for) if IndoorModel.respond_to?(:for)
          @original_release = IndoorModel.method(:release) if IndoorModel.respond_to?(:release)
          IndoorModel.define_singleton_method(:for) { |model| model.runtime }
          IndoorModel.define_singleton_method(:release) { |_model| true }
        end

        def teardown
          IndoorGmlConverter::ValidationSession.reset!
          restore_indoor_model_singleton(:for, @original_for)
          restore_indoor_model_singleton(:release, @original_release)
        end

        def test_new_model_cancels_validation_session_even_when_model_object_is_reused
          model = FakeModel.new
          progress = FakeProgress.new
          session = build_session(model, progress)
          observer = Indoor3DGmlAppObserver.new

          observer.onNewModel(model)

          assert_equal :cancelled, session.status
          assert_equal :model_changed, session.cancel_reason
          assert_equal 1, progress.close_count
          assert_nil IndoorGmlConverter::ValidationSession.for_model(model)
          assert_equal 1, model.runtime.refreshes
        end

        def test_open_model_cancels_validation_session_even_when_model_object_is_reused
          model = FakeModel.new
          progress = FakeProgress.new
          session = build_session(model, progress)
          observer = Indoor3DGmlAppObserver.new

          observer.onOpenModel(model)

          assert_equal :cancelled, session.status
          assert_equal :model_changed, session.cancel_reason
          assert_equal 1, progress.close_count
          assert_nil IndoorGmlConverter::ValidationSession.for_model(model)
          assert_equal 1, model.runtime.refreshes
        end

        private

        def build_session(model, progress)
          IndoorGmlConverter::ValidationSession.new(
            model: model,
            indoor_model: FakeIndoorModel.new(model),
            progress: progress,
            state: {}
          )
        end

        def restore_indoor_model_singleton(name, original)
          if original
            IndoorModel.define_singleton_method(name) { |*args| original.call(*args) }
          elsif IndoorModel.respond_to?(name)
            IndoorModel.singleton_class.remove_method(name)
          end
        rescue NameError
          nil
        end

        class FakeModel
          attr_reader :runtime

          def initialize
            @runtime = FakeRuntime.new
            @observers = []
          end

          def add_observer(observer)
            @observers << observer
          end

          def remove_observer(observer)
            @observers.delete(observer)
          end
        end

        FakeIndoorModel = Struct.new(:model)

        class FakeRuntime
          attr_reader :refreshes

          def initialize
            @refreshes = 0
          end

          def refresh_runtime_data
            @refreshes += 1
          end
        end

        class FakeProgress
          attr_reader :close_count

          def initialize
            @close_count = 0
          end

          def close
            @close_count += 1
          end

          def clear_callbacks; end
        end
      end
    end
  end
end
