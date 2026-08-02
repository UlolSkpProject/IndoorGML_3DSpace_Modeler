# frozen_string_literal: true

require_relative '../../application/progress/cooperative_fiber_runner'
require_relative '../../application/progress/cooperative_progress_runtime'
require_relative '../overlays/production_progress_live_elapsed'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceCreateCooperativeCommand
        def convert_selected_solid_groups_to_cell_spaces
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

          if @cell_space_create_runner&.active?
            UiFeedback.notify('CellSpace creation is already running.')
            return false
          end

          model = Sketchup.active_model()
          indoor_model = IndoorModel.current
          unless indoor_model.prepare_cell_space_creation_active_context(model)
            raise 'Failed to prepare active context for CellSpace conversion'
          end

          original_active_path = active_path_snapshot(model)
          groups = model.selection().to_a.select { |entity| convertible_container?(entity) }
          conversion_jobs = CellSpaceConversionJobBuilder.new(entities: groups).build

          if conversion_jobs.empty?
            UiFeedback.notify('Select one or more solid groups to convert to CellSpace.')
            return false
          end

          targets = conversion_jobs.map { |job| job[:target] }.compact.uniq
          storeys = conversion_jobs.map { |job| job[:storey].to_s }.reject(&:empty?).uniq
          creation_options = prompt_cell_space_creation_options(
            'Convert Solid Groups to CellSpace',
            default_target: targets.length == 1 ? targets.first : nil,
            default_storey: storeys.length == 1 ? storeys.first : CellSpace::DEFAULT_STOREY
          )
          return false unless creation_options

          cell_type, category_code, storey = creation_options
          conversion_jobs = CellSpaceConversionJobBuilder.apply_fallback_storey(conversion_jobs, storey)
          progress_session = start_cell_space_create_progress(model, conversion_jobs.length)

          start_cooperative_cell_space_conversion(
            model: model,
            indoor_model: indoor_model,
            conversion_jobs: conversion_jobs,
            fallback_target: [cell_type, category_code],
            original_active_path: original_active_path,
            progress_session: progress_session
          )
        rescue StandardError => e
          close_cell_space_create_progress(progress_session) if defined?(progress_session)
          UiFeedback.notify("CellSpace conversion failed:\n#{e.message}")
          false
        end

        private

        def start_cooperative_cell_space_conversion(
          model:,
          indoor_model:,
          conversion_jobs:,
          fallback_target:,
          original_active_path:,
          progress_session:
        )
          runner = ProductionProgress::CooperativeFiberRunner.new(model: model)
          @cell_space_create_runner = runner

          started = runner.start do |yield_control|
            begin
              result = indoor_model.convert_cell_space_jobs_bulk(
                conversion_jobs,
                fallback_target: fallback_target,
                original_active_path: original_active_path,
                operation_name: 'Convert Solid Groups to CellSpace',
                activate_root_context: true,
                progress: progress_session,
                yield_control: yield_control
              )
              finish_cell_space_create_progress(progress_session, result)
              close_cell_space_create_progress(progress_session)
              publish_cell_space_command_result(result)
            rescue StandardError => e
              fail_cell_space_create_progress(progress_session, e)
              close_cell_space_create_progress(progress_session)
              restore_cell_space_create_active_path(model, original_active_path)
              UiFeedback.notify("CellSpace conversion failed:\n#{e.message}")
            ensure
              close_cell_space_create_progress(progress_session)
              @cell_space_create_runner = nil
            end
          end

          unless started
            @cell_space_create_runner = nil
            close_cell_space_create_progress(progress_session)
            UiFeedback.notify('Failed to start cooperative CellSpace creation.')
            return false
          end

          true
        end

        def restore_cell_space_create_active_path(model, original_active_path)
          return unless model && original_active_path

          IndoorModel.current.with_active_path_enforcement_suspended do
            restore_active_path(model, original_active_path)
          end
          true
        rescue StandardError => e
          IndoorCore::Logger.puts(
            "[IndoorGML] Cooperative CellSpace active path restore failed: #{e.class}: #{e.message}"
          )
          false
        end
      end

      CellSpaceCommands.prepend(
        CellSpaceCreateCooperativeCommand
      ) unless CellSpaceCommands.ancestors.include?(
        CellSpaceCreateCooperativeCommand
      )
    end
  end
end
