# frozen_string_literal: true

# Run from SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/scripts/recenter_state_positions.rb'

repo_root = File.expand_path('..', __dir__)

[
  'indoor3d/utils/geometry/shell_analyzer.rb',
  'indoor3d/application/adjacency_service/geometry_query.rb',
  'indoor3d/application/indoor_model/scene_groups.rb',
  'indoor3d/application/indoor_model/feature_lifecycle.rb',
  'indoor3d/application/indoor_model/topology.rb'
].each do |relative_path|
  load File.join(repo_root, relative_path)
end

module ULOL
  module Indoor3DGmlModeler
    module Scripts
      module RecenterStatePositions
        module_function

        def run
          indoor_model = IndoorCore::IndoorModel.current
          indoor_model.refresh_runtime_data

          cell_spaces = indoor_model.cell_spaces.select { |cell_space| cell_space&.valid? }
          changed = 0
          failed = []

          indoor_model.send(:with_indoor_model_operation, 'IndoorGML Recenter State Positions') do
            cell_spaces.each do |cell_space|
              before = state_position(cell_space)
              indoor_model.send(:recenter_cell_space_origin, cell_space)
              indoor_model.send(:write_attributes, cell_space)
              after = state_position(cell_space)

              changed += 1 if before && after && before.distance(after) > 0.001
            rescue StandardError => e
              failed << [cell_space&.id, e]
            end

            cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              indoor_model.send(:synchronize_adjacency_and_transitions_for_cell_space, cell_space)
            rescue StandardError => e
              failed << [cell_space&.id, e]
            end
          end

          indoor_model.send(:invalidate_overlay_transition_points)
          Sketchup.active_model&.active_view&.invalidate

          report(cell_spaces.length, changed, failed)
        end

        def state_position(cell_space)
          cell_space&.duality_state&.position&.clone
        rescue StandardError
          nil
        end
        private_class_method :state_position

        def report(total, changed, failed)
          message = +"Recenter State Positions finished.\n"
          message << "CellSpaces checked: #{total}\n"
          message << "State positions moved: #{changed}\n"
          message << "Failures: #{failed.length}"

          failed.first(10).each do |id, error|
            message << "\n- #{id || '(unknown)'}: #{error.class}: #{error.message}"
          end

          UI.messagebox(message) if defined?(UI)
          puts message
          { total: total, changed: changed, failed: failed.length }
        end
        private_class_method :report
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::Scripts::RecenterStatePositions.run
