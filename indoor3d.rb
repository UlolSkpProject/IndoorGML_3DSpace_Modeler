# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module ULOL
  module Indoor3DGmlModeler
    unless const_defined?(:EXTENSION, false)
      EXTENSION = SketchupExtension.new(
        'Indoor3DGML Modeler',
        File.join(__dir__, 'indoor3d', 'core')
      )
      EXTENSION.creator = 'DKIM'
      EXTENSION.description = 'Create, import, export, and validate IndoorGML models.'
      EXTENSION.version = '1.0.0'
      EXTENSION.copyright = ''

      Sketchup.register_extension(EXTENSION, true)
    end
  end
end
