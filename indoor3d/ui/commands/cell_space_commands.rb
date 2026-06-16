# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceCommands
        def convert_selected_solid_groups_to_cell_spaces
          begin
            model = Sketchup.active_model()
            original_active_path = active_path_snapshot(model)
            groups = model.selection().to_a.select { |entity| convertible_container?(entity) }
            conversion_jobs = selected_cell_space_conversion_jobs(groups)

            if conversion_jobs.empty?
              UI.messagebox('Select one or more solid groups to convert to CellSpace.')
              return
            end

            if conversion_jobs.any? { |job| job[:target].nil? }
              cell_type, category_code = prompt_cell_space_type_and_category('Convert Solid Groups to CellSpace')
              return if cell_type.nil?
            end

            indoor_model = IndoorModel.current
            converted_count = 0
            errors = []

            model.start_operation('Convert Solid Groups to CellSpace', true)
            indoor_model.with_active_path_enforcement_suspended do
              activate_root_context(model)
              if conversion_jobs.empty?
                restore_active_path(model, original_active_path)
                model.abort_operation()
                UI.messagebox('No valid solid groups were available for conversion.')
                return
              end

              scheduled = indoor_model.run_batched(
                conversion_jobs,
                message: 'Converting CellSpaces...',
                batch_size: 20,
                complete: proc do
                  indoor_model.with_active_path_enforcement_suspended do
                    restore_active_path(model, original_active_path)
                  end
                  model.commit_operation()

                  UI.messagebox(ConversionMessageFormatter.result_message(converted_count, errors))
                end,
                failure: proc do |error|
                  indoor_model.with_active_path_enforcement_suspended do
                    restore_active_path(model, original_active_path)
                  end
                  model.abort_operation()
                  UI.messagebox("CellSpace conversion failed:\n#{error.message}")
                end
              ) do |job, _index|
                begin
                  target_cell_type, target_category_code = job[:target] || [cell_type, category_code]
                  source = copy_job_source_to_root(model, job)
                  indoor_model.convert_single_group_to_cell_space(source, target_cell_type, target_category_code)
                  job[:source].erase! if job[:source]&.valid?
                  cleanup_empty_conversion_ancestors(job)
                  converted_count += 1
                rescue StandardError => e
                  Logger.puts "[IndoorGML] CellSpace conversion failed: #{e.class}: #{e.message}"
                  source.erase! if source&.valid? && indoor_feature(source) != 'CellSpace'
                  errors << { group: ConversionMessageFormatter.group_label(job[:source]), reason: e.message }
                end
              end
              unless scheduled
                restore_active_path(model, original_active_path)
                model.abort_operation()
                UI.messagebox('CellSpace conversion could not be scheduled.')
              end
            end
          rescue StandardError => e
            if model && original_active_path
              IndoorModel.current.with_active_path_enforcement_suspended do
                restore_active_path(model, original_active_path)
              end
            end
            model.abort_operation() if model
            UI.messagebox("CellSpace conversion failed:\n#{e.message}")
          end
        end

        def change_selected_cell_space_type
          model = Sketchup.active_model
          groups = model.selection.to_a.select { |entity| convertible_container?(entity) }

          if groups.empty?
            UI.messagebox('Select one or more CellSpace groups to change type.')
            return
          end

          cell_space_groups = groups.select { |group| indoor_feature(group) == 'CellSpace' }
          if cell_space_groups.empty?
            UI.messagebox('Select one or more CellSpace groups to change type.')
            return
          end

          unless cell_space_type_change_available?(cell_space_groups)
            UI.messagebox('Selected CellSpace type is locked by Tag and already matches the mapped type.')
            return
          end

          cell_type, category_code = prompt_cell_space_type_and_category('Change CellSpace Type')
          return if cell_type.nil?

          indoor_model = IndoorModel.current
          changed_count = 0
          errors = []

          model.start_operation('Change CellSpace Type', true)
          cell_space_groups.each do |group|
            begin
              indoor_model.change_cell_space_type(group, cell_type, category_code)
              changed_count += 1
            rescue StandardError => e
              Logger.puts "[IndoorGML] CellSpace type change failed: #{e.class}: #{e.message}"
              errors << "#{group.name}: #{e.message}"
            end
          end
          model.commit_operation

          message = "Changed #{changed_count} CellSpace type(s)."
          message += "\nFailed #{errors.length} group(s):\n#{errors.join("\n")}" if errors.any?
          UI.messagebox(message)
        rescue StandardError => e
          model.abort_operation if model
          UI.messagebox("CellSpace type change failed:\n#{e.message}")
        end

        private

        def selected_cell_space_conversion_jobs(groups)
          parent_target = active_context_parent_tag_target
          active_ancestors = active_context_conversion_ancestors
          groups.each_with_object([]) do |group, jobs|
            collect_cell_space_conversion_jobs(
              group,
              Utils::Transformation.entity_transformation_in_active_context(group),
              parent_target,
              active_ancestors,
              jobs
            )
          end
        end

        def active_context_parent_tag_target
          parent = Sketchup.active_model&.active_path&.last
          parent ? tag_cell_space_type_and_category(parent) : nil
        rescue StandardError
          nil
        end

        def active_context_conversion_ancestors
          (Sketchup.active_model&.active_path || []).select { |entity| cleanup_candidate_container?(entity) }
        rescue StandardError
          []
        end

        def collect_cell_space_conversion_jobs(entity, world_transformation, parent_target, ancestors, jobs)
          return unless entity&.valid?
          return unless convertible_container?(entity)
          return if indoor_feature(entity) == 'CellSpace'

          if entity.respond_to?(:manifold?) && entity.manifold?
            jobs << {
              source: entity,
              transformation: world_transformation,
              ancestors: ancestors.dup,
              target: target_for_selected_entity(entity, parent_target)
            }
            return
          end

          entity_target = tag_cell_space_type_and_category(entity)
          return unless entity.respond_to?(:definition) && entity.definition&.valid?

          child_ancestors = cleanup_candidate_container?(entity) ? ancestors + [entity] : ancestors
          entity.definition.entities.to_a.each do |child|
            next unless child&.valid?
            next unless convertible_container?(child)

            collect_cell_space_conversion_jobs(
              child,
              world_transformation * child.transformation,
              entity_target,
              child_ancestors,
              jobs
            )
          end
        end

        def target_for_selected_entity(entity, parent_target)
          entity_target = tag_cell_space_type_and_category(entity)
          return entity_target if entity_target
          return parent_target unless tag_assigned?(entity)

          nil
        end

        def copy_job_source_to_root(model, job)
          source = job[:source]
          copy = model.entities.add_instance(source.definition, job[:transformation])
          copy = copy.to_group if source.is_a?(Sketchup::Group) && copy.respond_to?(:to_group)
          copy.make_unique if source.is_a?(Sketchup::Group) && copy.respond_to?(:make_unique)
          copy.name = source.name if copy.respond_to?(:name=) && source.respond_to?(:name)
          copy.material = source.material if copy.respond_to?(:material=) && source.respond_to?(:material)
          copy.layer = source.layer if copy.respond_to?(:layer=) && source.respond_to?(:layer)
          copy.visible = source.visible? if copy.respond_to?(:visible=) && source.respond_to?(:visible?)
          copy
        end

        def cleanup_empty_conversion_ancestors(job)
          Array(job[:ancestors]).reverse_each do |entity|
            cleanup_empty_conversion_container(entity)
          end
        end

        def cleanup_empty_conversion_container(entity)
          return false unless cleanup_candidate_container?(entity)
          return false unless entity.respond_to?(:definition) && entity.definition&.valid?
          return false unless entity.definition.entities.to_a.empty?

          entity.erase!
          true
        rescue StandardError => e
          Logger.puts "[IndoorGML] Empty source group cleanup failed: #{e.class}: #{e.message}"
          false
        end

        def cleanup_candidate_container?(entity)
          entity&.valid? &&
            convertible_container?(entity) &&
            indoor_feature(entity).to_s.empty?
        rescue StandardError
          false
        end
      end
    end
  end
end
