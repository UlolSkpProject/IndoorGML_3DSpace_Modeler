# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        attr_accessor :operation_names, :raise_after_operations
        attr_reader :operation_calls

        def initialize
          @operation_names = []
          @operation_calls = []
          @raise_after_operations = false
        end

        def local_vertex_normalize(*_args, **_options)
          operation_names.each do |name|
            with_indoor_model_operation(name) { true }
          end
          raise 'forced failure' if raise_after_operations

          :baseline
        end

        def with_indoor_model_operation(name, **options)
          @operation_calls << [name, options]
          yield
        end
      end
    end
  end
end

require_relative '../indoor3d/application/precision_validation/lvn_operation_ownership'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationLvnOperationOwnershipTest < Minitest::Test
        LVN_NAMES = [
          'IndoorGML Local Vertex Normalize',
          'IndoorGML LVN A',
          'IndoorGML LVN Topology Synchronize',
          'Reset CellSpace LVN Failure A',
          'Mark CellSpace LVN Failure A'
        ].freeze

        def test_continue_policy_forces_only_precision_lvn_operations
          model = IndoorModel.new
          model.operation_names = LVN_NAMES + ['Unrelated Operation']

          assert_equal :baseline,
                       model.local_vertex_normalize(failure_policy: :continue)

          forced = model.operation_calls.to_h
          LVN_NAMES.each do |name|
            assert_equal true, forced.fetch(name).fetch(:force)
          end
          refute forced.fetch('Unrelated Operation').key?(:force)
        end

        def test_default_policy_does_not_force_operations
          model = IndoorModel.new
          model.operation_names = LVN_NAMES

          assert_equal :baseline, model.local_vertex_normalize
          assert model.operation_calls.all? { |_name, options| !options.key?(:force) }
        end

        def test_scope_is_cleared_after_failure
          model = IndoorModel.new
          model.operation_names = ['IndoorGML LVN A']
          model.raise_after_operations = true

          assert_raises(RuntimeError) do
            model.local_vertex_normalize(failure_policy: :continue)
          end
          assert_equal true, model.operation_calls.last[1][:force]

          model.raise_after_operations = false
          model.operation_calls.clear
          model.with_indoor_model_operation('IndoorGML LVN A') { true }
          refute model.operation_calls.last[1].key?(:force)
        end

        def test_nested_continue_scopes_restore_depth
          model = IndoorModel.new
          model.operation_names = ['IndoorGML LVN A']

          model.singleton_class.class_eval do
            alias_method :baseline_local_vertex_normalize, :local_vertex_normalize

            define_method(:local_vertex_normalize) do |*args, **options|
              if options.delete(:nested)
                baseline_local_vertex_normalize(*args, **options) do
                  baseline_local_vertex_normalize(*args, **options)
                end
              else
                baseline_local_vertex_normalize(*args, **options)
              end
            end
          end

          assert_equal :baseline,
                       model.local_vertex_normalize(
                         failure_policy: :continue,
                         nested: false
                       )
          assert_equal true, model.operation_calls.last[1][:force]
        end
      end
    end
  end
end
