# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'
require_relative 'indoor3d/definition'

module ULOL
  module Indoor3DGmlModeler

    unless const_defined?(:EXTENSION, false)
      set_constant = lambda do |name, value|
        remove_const(name) if const_defined?(name, false)
        const_set(name, value)
      end

      set_constant.call(:EXTENSION_NAME, 'IndoorGML Modeler'.freeze)
      set_constant.call(:EXTENSION_VERSION, '1.0.7'.freeze)
      set_constant.call(:EXTENSION_CREATOR, 'ULOL'.freeze)
      set_constant.call(
        :EXTENSION_DESCRIPTION,
        'IndoorGML(v1.0.3) 실내 공간 모델구축,  CellSpace 변환, 위상 연결, GML 내보내기, 유효성 검증 도구'.freeze
      )
      set_constant.call(
        :EXTENSION,
        SketchupExtension.new(
          EXTENSION_NAME,
          File.join(__dir__, 'indoor3d', 'loader')
        )
      )
      EXTENSION.creator = EXTENSION_CREATOR
      EXTENSION.description = EXTENSION_DESCRIPTION
      EXTENSION.version = EXTENSION_VERSION
      EXTENSION.copyright = ''

      Sketchup.register_extension(EXTENSION, true)
    end
  end
end
