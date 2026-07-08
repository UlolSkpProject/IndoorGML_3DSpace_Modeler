# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module DualOverlayPreferences
        STATE_RADIUS_SCALE_KEY = 'dual_overlay_state_radius_scale'
        STATE_RADIUS_SCALE_DEFAULT = 1.0
        STATE_RADIUS_SCALE_MIN = 0.5
        STATE_RADIUS_SCALE_MAX = 2.0

        class << self
          def state_radius_scale
            UserPreferences.read_float(
              STATE_RADIUS_SCALE_KEY,
              fallback: STATE_RADIUS_SCALE_DEFAULT,
              min: STATE_RADIUS_SCALE_MIN,
              max: STATE_RADIUS_SCALE_MAX
            )
          end

          def state_radius_scale=(value)
            UserPreferences.write_float(
              STATE_RADIUS_SCALE_KEY,
              value,
              fallback: STATE_RADIUS_SCALE_DEFAULT,
              min: STATE_RADIUS_SCALE_MIN,
              max: STATE_RADIUS_SCALE_MAX
            )
          end
        end
      end
    end
  end
end
