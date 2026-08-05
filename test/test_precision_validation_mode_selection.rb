# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        FAST_PROFILE = :fast
        PRECISION_PROFILE = :precision
        PROFILE_THREAD_KEY = :test_precision_validation_profile

        module_function

        def with_profile(profile)
          previous = Thread.current[PROFILE_THREAD_KEY]
          Thread.current[PROFILE_THREAD_KEY] = profile
          yield
        ensure
          Thread.current[PROFILE_THREAD_KEY] = previous
        end

        def current_profile
          Thread.current[PROFILE_THREAD_KEY] || FAST_PROFILE
        end
      end

      class CommandDispatcher
        attr_reader :executed_profiles
        attr_accessor :running

        def initialize
          @executed_profiles = []
          @running = false
        end

        def validation_operation_running?
          @running == true
        end

        def check_validity
          @executed_profiles << PrecisionValidation.current_profile
          :executed
        end
      end
    end
  end
end

require_relative '../indoor3d/ui/validity_mode_dialog'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ValidityModeDialog
        class << self
          attr_accessor :selection_callback, :show_count

          def show(&block)
            self.show_count = show_count.to_i + 1
            self.selection_callback = block
            :dialog
          end
        end
      end
    end
  end
end

require_relative '../indoor3d/application/precision_validation/validation_mode_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationModeSelectionTest < Minitest::Test
        def setup
          ValidityModeDialog.selection_callback = nil
          ValidityModeDialog.show_count = 0
        end

        def test_check_validity_opens_mode_dialog_without_running_validation
          dispatcher = CommandDispatcher.new

          assert_equal true, dispatcher.check_validity
          assert_equal 1, ValidityModeDialog.show_count
          assert_empty dispatcher.executed_profiles
        end

        def test_fast_selection_runs_existing_fast_pipeline
          dispatcher = CommandDispatcher.new
          dispatcher.check_validity

          ValidityModeDialog.selection_callback.call(:fast)

          assert_equal [:fast], dispatcher.executed_profiles
        end

        def test_precision_selection_runs_precision_profile
          dispatcher = CommandDispatcher.new
          dispatcher.check_validity

          ValidityModeDialog.selection_callback.call(:precision)

          assert_equal [:precision], dispatcher.executed_profiles
        end

        def test_direct_precision_entry_does_not_open_selection_dialog
          dispatcher = CommandDispatcher.new

          assert_equal :executed, dispatcher.check_precision_validity
          assert_equal [:precision], dispatcher.executed_profiles
          assert_equal 0, ValidityModeDialog.show_count
        end

        def test_running_validation_blocks_dialog_and_new_execution
          dispatcher = CommandDispatcher.new
          dispatcher.running = true

          assert_equal false, dispatcher.check_validity
          assert_equal 0, ValidityModeDialog.show_count
          assert_empty dispatcher.executed_profiles
        end
      end
    end
  end
end
