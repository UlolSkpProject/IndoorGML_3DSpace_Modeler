# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module ULOL
  module Indoor3DGmlModeler
    unless const_defined?(:EXTENSION, false)
      EXTENSION_NAME = "IndoorGML 3D Modeler"
      EXTENSION_VERSION = "1.0.0"
      EXTENSION_CREATOR = "ULOL"
      EXTENSION_DESCRIPTION = 'Create, import, export, and validate IndoorGML models.'

      EXTENSION = SketchupExtension.new(
        EXTENSION_NAME,
        File.join(__dir__, 'indoor3d', 'core')
      )
      EXTENSION.creator = EXTENSION_CREATOR
      EXTENSION.description = EXTENSION_DESCRIPTION
      EXTENSION.version = EXTENSION_VERSION
      EXTENSION.copyright = ''

      Sketchup.register_extension(EXTENSION, true)
    end
  end
end
