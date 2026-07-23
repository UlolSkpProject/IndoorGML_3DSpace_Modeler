# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module DualOverlayPreferences
        STATE_SCALE_KEY = 'dual_overlay_state_scale'
        STATE_SCALE_DEFAULT = 1.0
        STATE_SCALE_MIN = 0.1
        STATE_SCALE_MAX = 3.0

        class << self
          def state_radius_scale
            UserPreferences.read_float(
              STATE_SCALE_KEY,
              fallback: STATE_SCALE_DEFAULT,
              min: STATE_SCALE_MIN,
              max: STATE_SCALE_MAX
            )
          end

          def state_radius_scale=(value)
            UserPreferences.write_float(
              STATE_SCALE_KEY,
              value,
              fallback: STATE_SCALE_DEFAULT,
              min: STATE_SCALE_MIN,
              max: STATE_SCALE_MAX
            )
          end
        end
      end
    end
  end
end
