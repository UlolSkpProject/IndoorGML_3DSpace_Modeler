require 'sketchup.rb'

module ULOL
  include Sketchup
  include Geom
  module Indoor3DGmlModeler

    load File.join(__dir__, 'classes', 'Gml', 'gml.rb')
    load File.join(__dir__, 'classes', 'IndoorCore', 'IndoorCore.rb')
    # load File.join(__dir__, 'classes', '', 'floor.rb')
    # load File.join(__dir__, 'classes', '', 'cell.rb')
    # load File.join(__dir__, 'services', '', 'node.rb')

  end
end
