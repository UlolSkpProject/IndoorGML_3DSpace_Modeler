# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        # Ensures precision-validation LVN write phases own a real SketchUp
        # operation even while observer routing is suppressed after an abort.
        # Existing caller-owned IndoorModel operations still take precedence
        # because RuntimeSupport checks operation depth before honoring `force`.
        module LvnOperationOwnershipPatch
          def local_vertex_normalize(*args, **options, &block)
            policy = options.fetch(:failure_policy, :rollback_all)
            continue_scope = policy.respond_to?(:to_sym) && policy.to_sym == :continue
            return super unless continue_scope

            @precision_validation_lvn_operation_scope_depth =
              @precision_validation_lvn_operation_scope_depth.to_i + 1
            super
          ensure
            if continue_scope
              @precision_validation_lvn_operation_scope_depth = [
                @precision_validation_lvn_operation_scope_depth.to_i - 1,
                0
              ].max
            end
          end

          def with_indoor_model_operation(name, **options, &block)
            if precision_validation_lvn_operation_scope? &&
               precision_validation_lvn_operation_name?(name)
              options = options.merge(force: true)
            end

            super(name, **options, &block)
          end

          private

          def precision_validation_lvn_operation_scope?
            @precision_validation_lvn_operation_scope_depth.to_i.positive?
          end

          def precision_validation_lvn_operation_name?(name)
            label = name.to_s
            label == 'IndoorGML Local Vertex Normalize' ||
              label.start_with?('IndoorGML LVN ') ||
              label.start_with?('Reset CellSpace LVN Failure ') ||
              label.start_with?('Mark CellSpace LVN Failure ')
          end
        end
      end

      IndoorModel.prepend(PrecisionValidation::LvnOperationOwnershipPatch)
    end
  end
end
