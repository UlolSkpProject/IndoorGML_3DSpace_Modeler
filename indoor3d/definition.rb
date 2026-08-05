# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Definition
      INDOOR_GML_STANDARD_VERSION = '1.0.3'
      INDOOR_GML_SCHEMA_VERSION = '1.0'
      STORAGE_FORMAT_VERSION = '1.0.3'
      APPLICATION_PROFILE_VERSION = '1'
      APPLICATION_PROFILE_ID = 'urn:ulol:indoorgml:profile:1'
      APPLICATION_PROFILE_NAME =
        'ULOL IndoorGML 1.0.3 application profile v1 — ' \
        'GML 3.2.1, 3D Solid with one exterior shell and no cavities, ' \
        'single SpaceLayer, volumetric thick-door without boundary export, ' \
        'Core/Navigation subset'

      # Backward-compatible name used by persisted model attributes.
      INDOOR_GML_VERSION = STORAGE_FORMAT_VERSION
      LOGGING_ENABLED = false
    end
  end
end
