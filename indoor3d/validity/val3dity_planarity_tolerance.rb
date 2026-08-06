# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityPlanarityTolerance
          OPTION = '--planarity_d2p_tol'
          DEFAULT_D2P_TOL = 0.025

          module_function

          def apply(args)
            command = Array(args).dup
            return command if command.include?(OPTION)

            report_index = command.index('-r') || command.length
            command.insert(
              report_index,
              OPTION,
              format('%.15g', DEFAULT_D2P_TOL)
            )
          end

          module ProcessAdapterPatch
            def initialize(args:, current_dir:)
              super(
                args: Val3dityPlanarityTolerance.apply(args),
                current_dir: current_dir
              )
            end
          end

          def install!
            return false unless defined?(Val3dityProcessAdapter)
            return true if Val3dityProcessAdapter.ancestors.include?(ProcessAdapterPatch)

            Val3dityProcessAdapter.prepend(ProcessAdapterPatch)
            true
          end
        end

        Val3dityPlanarityTolerance.install!
      end
    end
  end
end
