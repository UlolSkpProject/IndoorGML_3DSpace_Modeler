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

    def self.convert_selected_solid_groups_to_cell_spaces
      model = Sketchup.active_model
      groups = model.selection.grep(Sketchup::Group)
      solid_groups = groups.select { |group| group.valid? && group.manifold? }

      if solid_groups.empty?
        UI.messagebox('Select one or more solid groups to convert to CellSpace.')
        return
      end

      labels = IndoorCore::CellSpaceType::LABELS.values
      result = UI.inputbox(
        ['CellSpace Type'],
        [labels.first],
        [labels.join('|')],
        'Convert Solid Groups to CellSpace'
      )
      return unless result

      cell_type = IndoorCore::CellSpaceType.from_label(result.first)
      indoor_model = IndoorCore::IndoorModel.current
      converted_count = 0
      failed_count = 0

      model.start_operation('Convert Solid Groups to CellSpace', true)
      solid_groups.each do |group|
        begin
          indoor_model.convert_group_to_cell_space(group, cell_type)
          converted_count += 1
        rescue StandardError
          failed_count += 1
        end
      end
      model.commit_operation

      message = "Converted #{converted_count} CellSpace(s)."
      message += "\nFailed #{failed_count} group(s)." if failed_count.positive?
      UI.messagebox(message)
    rescue StandardError => e
      model.abort_operation if model
      UI.messagebox("CellSpace conversion failed:\n#{e.message}")
    end

    unless file_loaded?(__FILE__)
      menu = UI.menu('Extensions').add_submenu('Indoor3DGML Modeler')
      menu.add_item('Convert Solid Groups to CellSpace') do
        convert_selected_solid_groups_to_cell_spaces
      end
      file_loaded(__FILE__)
    end

  end
end
