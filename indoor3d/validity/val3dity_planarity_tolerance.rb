# frozen_string_literal: true

require_relative '../export/gml_exporter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityPlanarityTolerance
          OPTION = '--planarity_d2p_tol'
          DEFAULT_D2P_TOL_MM = 0.025

          module_function

          def apply(args, model:)
            command = Array(args).dup
            return command if command.include?(OPTION)

            raise ArgumentError, 'SketchUp model is required for physical planarity tolerance' unless model

            # GML coordinates follow the SketchUp model length unit.
            tolerance = GmlExporter.millimeters_to_coordinate_units(
              DEFAULT_D2P_TOL_MM, model: model
            )
            report_index = command.index('-r') || command.length
            command.insert(report_index, OPTION, format('%.15g', tolerance))
          end

          module ProcessAdapterPatch
            def initialize(args:, current_dir:, model: nil)
              model ||= Sketchup.active_model if defined?(Sketchup) && Sketchup.respond_to?(:active_model)
              super(
                args: Val3dityPlanarityTolerance.apply(args, model: model),
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
