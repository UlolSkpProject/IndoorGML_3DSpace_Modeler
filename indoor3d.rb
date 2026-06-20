# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module ULOL
  module Indoor3DGmlModeler

    unless const_defined?(:EXTENSION, false)
      EXTENSION_NAME = "IndoorGML 3D Modeler"
      EXTENSION_VERSION = "1.2.4"
      EXTENSION_CREATOR = "ULOL"
      EXTENSION_DESCRIPTION = 'SketchUp2026에서 IndoorGML(v1.0) 실내 공간 모델을 구축하고 CellSpace 변환, 위상 연결, GML 내보내기, geometry 검증을 수행하는 Extension.'

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
