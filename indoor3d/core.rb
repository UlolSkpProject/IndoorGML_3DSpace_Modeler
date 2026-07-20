require 'sketchup.rb'
require_relative 'definition'

module ULOL
  include Sketchup
  include Geom
  module Indoor3DGmlModeler

    require_relative 'utils/logger'
    require_relative 'utils/change_snapshot'
    require_relative 'utils/geometry'
    require_relative 'utils/transformation'
    require_relative 'utils/materials'
    require_relative 'utils/hermite_spline'

   