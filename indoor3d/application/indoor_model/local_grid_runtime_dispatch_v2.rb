# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module LocalGridCoordinateV2
          # Keep the legacy RuntimeSupport#refresh_runtime_data unchanged. While
          # Local Grid V2 is enabled for this IndoorModel instance, ordinary
          # internal refresh calls are dispatched to the V2 refresh path so they
          # cannot fall back into legacy recenter -> axis alignment behavior.
          def refresh_runtime_data(initial_model_load: false)
            return super unless local_grid_coordinate_v2_enabled?

            refresh_runtime_data_local_grid_v2_without_activation(
              initial_model_load: initial_model_load
            )
          end
        end
      end
    end
  end
end
