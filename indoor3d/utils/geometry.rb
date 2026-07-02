# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        SHELL_CENTER_COARSE_DIVISIONS = 8 unless const_defined?(:SHELL_CENTER_COARSE_DIVISIONS, false)
        SHELL_CENTER_REFINE_DIVISIONS = 4 unless const_defined?(:SHELL_CENTER_REFINE_DIVISIONS, false)
        SHELL_CENTER_TOLERANCE = 0.001 unless const_defined?(:SHELL_CENTER_TOLERANCE, false)
        DEFAULT_TOLERANCE = 0.001 unless const_defined?(:DEFAULT_TOLERANCE, false)
      end
    end
  end
end

require_relative 'geometry/polygon2d'
require_relative 'geometry/polygon2d_public_api'
require_relative 'geometry/adjacency_detector'
require_relative 'geometry/shell_analyzer'
require_relative 'geometry/source_group'
