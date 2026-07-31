# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class AppObserver; end unless const_defined?(:AppObserver, false)
  class ModelObserver; end unless const_defined?(:ModelObserver, false)
end

module UI
  class << self
    attr_reader :scheduled_timers

    def start_timer(delay, repeat = false, &block)
      @scheduled_timers ||= []
      @scheduled_timers << { delay: delay, repeat: repeat, block: block }
      @scheduled_timers.length
    end

    def run_scheduled_timers
      timers = Array(@scheduled_timers)
      @scheduled_timers = []
      timers.each { |timer| timer[:block].call }
    end

    def reset_scheduled_timers
      @scheduled_timers = []
    end
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)

      class Indoor3DGmlModelObserver < Sketchup::ModelObserver
        def initialize(on_delete_model: nil, **_options)
          @on_delete_model = on_delete_model
        end

        def onDeleteModel(model)
          @on_delete_model&.call(model)
        end

        def forget_model(_model); end
      end unless const_defined?(:Indoor3DGmlModelObserver)

      class IndoorModel; end unless const_defined?(:IndoorModel)
    end
  end
end

require_relative '../indoor3d/validity/validation_session'
require_relative '../indoor3d/validity/val3dity_runner'
require_relative '../indoor3d/infrastructure/observers/app_observer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AppObserverValidationSessionsTest < Minitest::Test
        def setup
          UI.reset_scheduled_timers
          IndoorGmlConverter::ValidationSession.reset!
          IndoorGmlConverter::Val3dityRunner.instance_variable_set(:@shutting_down, false)
          IndoorGmlConverter::Val3dityRunner.active_sessions.clear
          IndoorGmlConverter::Val3dityRunner.session_owner_keys.clear
          @original_for = IndoorModel.method(:for) if IndoorModel.respond_to?(:for)
          @original_release = IndoorModel.method(:release) if IndoorModel.respond_to?(:release)
          @released_models = []
          released_models = @released_models
          IndoorModel.define_singleton_method(:for) { |model| model.runtime }
          IndoorModel.define_singleton_method(:release) { |model| released_models << model }
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
          assert_equal 0, model.runtime.refreshes
          assert_equal [0.5], UI.scheduled_timers.map { |timer| timer[:delay] }

          UI.run_scheduled_timers

          assert_equal 1, model.runtime.refreshes
          assert_equal [true], model.runtime.initial_model_load_flags
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
          assert_equal 0, model.runtime.refreshes
          assert_equal [0.5], UI.scheduled_timers.map { |timer| timer[:delay] }

          UI.run_scheduled_timers

          assert_equal 1, model.runtime.refreshes
          assert_equal [true], model.runtime.initial_model_load_flags
        end

        def test_duplicate_initial_refresh_requests_share_one_timer_and_one_refresh
          model = FakeModel.new
          observer = Indoor3DGmlAppObserver.new

          assert observer.schedule_initial_refresh(model)
          refute observer.schedule_initial_refresh(model)
          observer.onOpenModel(model)

          assert_equal 1, UI.scheduled_timers.length
          assert_equal :scheduled, observer.instance_variable_get(:@initial_refresh_states)[model.object_id]

          UI.run_scheduled_timers

          assert_equal 1, model.runtime.refreshes
          assert_equal :complete, observer.instance_variable_get(:@initial_refresh_states)[model.object_id]
          refute observer.schedule_initial_refresh(model)
          assert_empty UI.scheduled_timers
        end

        def test_failed_initial_refresh_can_be_scheduled_again
          model = FakeModel.new
          model.runtime.fail_next_refresh = true
          observer = Indoor3DGmlAppObserver.new

          assert observer.schedule_initial_refresh(model)
          UI.run_scheduled_timers

          refute observer.instance_variable_get(:@initial_refresh_states).key?(model.object_id)
          assert observer.schedule_initial_refresh(model)
          UI.run_scheduled_timers

          assert_equal 1, model.runtime.refreshes
          assert_equal :complete, observer.instance_variable_get(:@initial_refresh_states)[model.object_id]
        end

        def test_releasing_model_cancels_pending_initial_refresh
          model = FakeModel.new
          observer = Indoor3DGmlAppObserver.new
          observer.register_model(model)
          assert observer.schedule_initial_refresh(model)

          model.observers.first.onDeleteModel(model)
          UI.run_scheduled_timers

          assert_equal 0, model.runtime.refreshes
          refute observer.instance_variable_get(:@initial_refresh_states).key?(model.object_id)
        end

        def test_extension_load_delegates_to_the_same_initial_refresh_scheduler
          source = File.read(File.expand_path('../indoor3d/core.rb', __dir__))

          assert_includes source, '@app_observer.schedule_initial_refresh(model)'
          refute_includes source, 'UI.start_timer(0.5, false)'
          refute_includes source, 'IndoorModel.current.refresh_runtime_data(initial_model_load: true)'
        end

        def test_repeated_open_and_delete_releases_every_model_and_observer_registration
          observer = Indoor3DGmlAppObserver.new
          models = 10.times.map { FakeModel.new }

          models.each do |model|
            observer.onOpenModel(model)
            model.observers.first.onDeleteModel(model)
          end

          assert_equal models, @released_models
          assert_empty observer.instance_variable_get(:@observed_model_ids)
          assert models.all? { |model| model.observers.empty? }
        end

        def test_quit_marks_global_shutdown_and_terminates_all_runners
          observer = Indoor3DGmlAppObserver.new
          runner_session = FakeRunnerSession.new
          IndoorGmlConverter::Val3dityRunner.register_session(runner_session)

          observer.onQuit

          assert IndoorGmlConverter::Val3dityRunner.shutting_down?
          assert_equal [0], runner_session.terminate_waits
          assert_empty IndoorGmlConverter::Val3dityRunner.active_sessions
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
          attr_reader :observers

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
          attr_reader :initial_model_load_flags
          attr_accessor :fail_next_refresh

          def initialize
            @refreshes = 0
            @initial_model_load_flags = []
          end

          def refresh_runtime_data(initial_model_load: false)
            if @fail_next_refresh
              @fail_next_refresh = false
              raise 'refresh failed'
            end

            @refreshes += 1
            @initial_model_load_flags << initial_model_load
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

        class FakeRunnerSession
          attr_reader :terminate_waits

          def initialize
            @terminate_waits = []
          end

          def terminate(wait_ms:)
            @terminate_waits << wait_ms
          end
        end
      end
    end
  end
end
