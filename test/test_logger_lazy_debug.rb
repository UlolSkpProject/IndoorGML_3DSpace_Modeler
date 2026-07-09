# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class ModelObserver; end unless const_defined?(:ModelObserver, false)
end

require_relative '../indoor3d/utils/logger'
require_relative '../indoor3d/infrastructure/observers/observer_helpers'
require_relative '../indoor3d/infrastructure/observers/model_observer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LoggerLazyDebugTest < Minitest::Test
        def setup
          @original_level = Logger.level
          @original_logging_enabled = Definition::LOGGING_ENABLED
          skip 'Logger tests are disabled when LOGGING_ENABLED=false' unless @original_logging_enabled == true
        end

        def teardown
          Logger.level = @original_level
          set_logging_enabled(@original_logging_enabled)
        end

        def test_debug_block_is_not_evaluated_when_debug_is_disabled
          %i[info warn error silent].each do |level|
            Logger.level = level
            calls = 0

            out, = capture_io do
              Logger.debug do
                calls += 1
                'expensive diagnostic'
              end
            end

            assert_equal 0, calls, "debug block evaluated at #{level}"
            assert_empty out
          end
        end

        def test_debug_block_is_evaluated_once_when_debug_is_enabled
          Logger.level = :debug
          calls = 0

          out, = capture_io do
            Logger.debug do
              calls += 1
              'expensive diagnostic'
            end
          end

          assert_equal 1, calls
          assert_equal "expensive diagnostic\n", out
        end

        def test_existing_string_api_remains_compatible
          Logger.level = :debug

          out, = capture_io do
            Logger.debug('debug message')
            Logger.info('info message')
            Logger.warn('warn message')
            Logger.error('error message')
            Logger.puts('puts message')
            Logger.info
          end

          assert_equal(
            "debug message\ninfo message\nwarn message\nerror message\nputs message\n",
            out
          )
        end

        def test_release_logging_flag_suppresses_debug_info_and_puts
          Logger.level = :debug
          set_logging_enabled(false)
          calls = 0

          out, = capture_io do
            Logger.debug('debug message')
            Logger.info('info message')
            Logger.puts('puts message')
            Logger.debug do
              calls += 1
              'expensive diagnostic'
            end
          end

          assert_empty out
          assert_equal 0, calls
        end

        def test_release_logging_flag_keeps_warn_and_error
          Logger.level = :silent
          set_logging_enabled(false)

          out, = capture_io do
            Logger.warn('warn message')
            Logger.error('error message')
          end

          assert_equal "warn message\nerror message\n", out
        end

        def test_observer_replay_context_is_not_computed_when_debug_is_disabled
          Logger.level = :info
          indoor_model = FakeIndoorModel.new
          observer = FakeObserver.new(indoor_model)

          out, = capture_io { observer.log_change(FakeEntity.new) }

          assert_empty out
          assert_equal 0, indoor_model.diagnostic_snapshot_count
        end

        def test_observer_replay_context_is_computed_when_debug_is_enabled
          Logger.level = :debug
          indoor_model = FakeIndoorModel.new
          observer = FakeObserver.new(indoor_model)

          out, = capture_io { observer.log_change(FakeEntity.new) }

          assert_includes out, 'FakeObserver#onChangeEntity'
          assert_includes out, 'dirty_queue=7'
          assert_equal 1, indoor_model.diagnostic_snapshot_count
        end

        def test_transaction_replay_diagnostic_is_not_computed_when_debug_is_disabled
          Logger.level = :info
          indoor_model = FakeIndoorModel.new
          observer = Indoor3DGmlModelObserver.new

          out, = capture_io do
            observer.send(
              :log_transaction_replay_callback,
              FakeModel.new,
              indoor_model,
              source: :undo,
              generation: 3
            )
          end

          assert_empty out
          assert_equal 0, indoor_model.diagnostic_snapshot_count
        end

        private

        def set_logging_enabled(value)
          Definition.send(:remove_const, :LOGGING_ENABLED) if Definition.const_defined?(:LOGGING_ENABLED, false)
          Definition.const_set(:LOGGING_ENABLED, value == true)
        end

        class FakeObserver
          include ObserverHelpers

          def initialize(indoor_model)
            @indoor_model = indoor_model
          end

          def log_change(entity)
            log_event('onChangeEntity', entity)
          end
        end

        class FakeIndoorModel
          attr_reader :diagnostic_snapshot_count

          def initialize
            @diagnostic_snapshot_count = 0
          end

          def diagnostic_snapshot
            @diagnostic_snapshot_count += 1
            { active_path: :primal, dirty_topology_count: 7 }
          end

          def transaction_replay_pending?
            true
          end

          def transaction_replay_source
            :undo
          end

          def transaction_replay_generation
            3
          end
        end

        class FakeEntity
          attr_reader :entityID, :persistent_id

          def initialize
            @entityID = 10
            @persistent_id = 20
          end

          def name
            'Cell A'
          end

          def get_attribute(_dictionary, key)
            key == 'feature' ? 'CellSpace' : nil
          end
        end

        class FakeModel
          def active_path
            []
          end
        end
      end
    end
  end
end
