# frozen_string_literal: true

require_relative 'cell_space_conversion_rollback_verification_patch'

ULOL::Indoor3DGmlModeler::IndoorCore::
  CellSpaceConversionRollbackFailureRunner.run!
