# frozen_string_literal: true

require_relative 'commands/base_commands'
require_relative 'commands/cell_space_commands'
require_relative 'commands/export_commands'
require_relative 'commands/display_commands'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CommandDispatcher
        include BaseCommands
        include CellSpaceCommands
        include ExportCommands
        include DisplayCommands

        attr_accessor :dual_overlay_command
        attr_accessor :geometry_command
      end
    end
  end
end
