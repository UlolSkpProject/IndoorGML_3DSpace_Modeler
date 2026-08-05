# frozen_string_literal: true

require_relative 'commands/conversion_message_formatter'
require_relative 'commands/base_commands'
require_relative 'commands/cell_space_commands'
require_relative '../application/progress/adjacency_progress_keyword_guard'
require_relative '../application/cell_space_behavior_policies'
require_relative 'commands/export_commands'
require_relative 'export_progress_cancel_visibility'
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

require_relative '../application/progress/runtime_refresh_progress_integration'
require_relative '../application/progress/gml_export_progress_integration'
require_relative '../application/progress/gml_export_progress_stage_order'
