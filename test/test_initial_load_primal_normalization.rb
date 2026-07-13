# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class << self
    attr_accessor :test_active_model
  end

  def self.active_model
    @test_active_model
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)

      class IndoorModel
      end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/runtime_support'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class InitialLoadPrimalNormalizationTest < Minitest::Test
        def test_initial_load_normalizes_after_discovery_and_before_runtime_restore
          indoor = Harness.new

          indoor.refresh_runtime_data(initial_model_load: true)

          assert_equal [
            :discover_primal,
            :normalize_primal,
            [:restore_runtime, true],
            :recenter,
            :materials,
            :adjacency
          ], indoor.events
          assert_equal ['IndoorGML Refresh Runtime Data'], indoor.operations
        end

        def test_regular_refresh_does_not_normalize_primal_children
          indoor = Harness.new

          indoor.refresh_runtime_data(initial_model_load: false)

          assert_equal [[:restore_runtime, true], :recenter, :adjacency], indoor.events
        end

        class Harness
          include IndoorModel::RuntimeSupport

          attr_reader :events, :operations

          def initialize
            @events = []
            @operations = []
            @cell_spaces = []
            @states = []
            @transitions = []
            @editor_session = Struct.new(:unused) do
              def apply_display_state; end
            end.new
          end

          private

          def with_indoor_model_operation(name, **_options)
            @operations << name
            yield
          end

          def guard_active?(flag)
            instance_variable_get(flag) == true
          end

          def with_guard_flag(flag)
            previous = instance_variable_get(flag)
            instance_variable_set(flag, true)
            yield
          ensure
            instance_variable_set(flag, previous)
          end

          def sync
            yield
          end

          def find_existing_space_features_groups
            @events << :discover_primal
          end

          def normalize_primal_children_for_initial_load
            @events << :normalize_primal
          end

          def restore_runtime_from_current_model(persist_repaired_ids: false)
            @events << [:restore_runtime, persist_repaired_ids]
          end

          def recenter_runtime_cell_spaces
            @events << :recenter
          end

          def apply_initial_cell_space_materials
            @events << :materials
          end

          def rebuild_runtime_transitions_from_cell_adjacency
            @events << :adjacency
          end

          def invalidate_overlay_transition_points; end

          def apply_indoor_lock_policy; end
        end
      end
    end
  end
end
