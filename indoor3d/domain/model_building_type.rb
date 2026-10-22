# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ModelBuildingType
        SUBWAY_FILENAME_PATTERN = /\AU_SB_\d{6}_.*\.skp\z/i.freeze
        MODEL_FILENAME_PATTERN = /\A[PU]_[^_]{2}_\d{6}_.*\.skp\z/i.freeze

        module_function

        def from_model(model)
          path = model.respond_to?(:path) ? model.path : ''
          from_path(path)
        end

        def from_path(path)
          filename = File.basename(path.to_s.tr('\\', '/'))
          return 'subway' if SUBWAY_FILENAME_PATTERN.match?(filename)
          return 'public' if MODEL_FILENAME_PATTERN.match?(filename)

          nil
        end
      end
    end
  end
end
