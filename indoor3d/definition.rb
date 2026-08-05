# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Definition
      INDOOR_GML_STANDARD_VERSION = '1.0.3'
      INDOOR_GML_SCHEMA_VERSION = '1.0'
      STORAGE_FORMAT_VERSION = '1.0.3'

      # Backward-compatible name used by persisted model attributes.
      INDOOR_GML_VERSION = STORAGE_FORMAT_VERSION
      LOGGING_ENABLED = false
    end
  end
end
