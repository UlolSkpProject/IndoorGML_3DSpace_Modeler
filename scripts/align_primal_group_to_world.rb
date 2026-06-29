# frozen_string_literal: true

# Run from SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/scripts/align_primal_group_to_world.rb'

repo_root = File.expand_path('..', __dir__)

unless defined?(ULOL::Indoor3DGmlModeler::IndoorCore::IndoorModel)
  load File.join(repo_root, 'indoor3d/core.rb')
end

module ULOL
  module Indoor3DGmlModeler
    module Scripts
      module AlignPrimalGroupToWorld
        module_function

        def run
          indoor_model = IndoorCore::IndoorModel.current
          indoor_model.finish_editing if indoor_model.editing?
          indoor_model.refresh_runtime_data

          primal_group = indoor_model.primal_group
          unless primal_group&.valid?
            return report(false, 'IndoorGML_PrimalSpaceFeatures group not found.')
          end

          before = primal_group.transformation
          indoor_model.send(:with_indoor_model_operation, 'IndoorGML Align Primal Group To World') do
            indoor_model.send(:ensure_primal_group_world_aligned)
          end
          indoor_model.refresh_runtime_data

          changed = !same_transformation?(before, Geom::Transformation.new)
          report(true, changed ? 'Primal group transform was absorbed into children.' : 'Primal group was already world aligned.')
        rescue StandardError => e
          report(false, "#{e.class}: #{e.message}")
        end

        def same_transformation?(first, second)
          values1 = first.to_a
          values2 = second.to_a
          values1.each_with_index.all? { |value, index| (value - values2[index]).abs <= 1.0e-9 }
        rescue StandardError
          false
        end
        private_class_method :same_transformation?

        def report(success, message)
          text = "Align Primal Group To World #{success ? 'finished' : 'failed'}.\n#{message}"
          UI.messagebox(text) if defined?(UI)
          puts text
          { success: success, message: message }
        end
        private_class_method :report
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::Scripts::AlignPrimalGroupToWorld.run
