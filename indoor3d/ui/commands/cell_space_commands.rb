# frozen_string_literal: true

require_relative '../ui_feedback'
require_relative '../../application/progress/production_progress_session'
require_relative '../overlays/production_progress_overlay'
require_relative '../../application/progress/cell_space_create_progress_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceVertexNormalizeProgressAdapter
        def initialize(session, logger: IndoorCore::Logger)
          @session = session
          @logger = logger
        end

        def active?
          @session&.active? == true
        end

        def detail(percent:, phase:, message:, current: nil)
          return false unless active?

          parts = [phase, message]
          parts << current unless current.to_s.empty?
          @session.update(
            completed: percent,
            message: parts.compact.map(&:to_s).reject(&:empty?).join(' - '),
            telemetry: {
              phase: phase,
              current: current
            }
          )
          true
        rescue StandardError => error
          @logger.puts(
            "[IndoorGML] Vertex Normalize progress update failed: " \
            "#{error.class}: #{error.message}"
          )
          false
        end
      end

      module CellSpaceCommands
        def convert_selected_solid_groups_to_cell_spaces
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

          progress_session = nil
          begin
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
              return
            end

            targets = conversion_jobs.map { |job| job[:target] }.compact.uniq
            storeys = conversion_jobs.map { |job| job[:storey].to_s }.reject(&:empty?).uniq
            creation_options = prompt_cell_space_creation_options(
              'Convert Solid Groups to CellSpace',
              default_target: targets.length == 1 ? targets.first : nil,
              default_storey: storeys.length == 1 ? storeys.first : CellSpace::DEFAULT_STOREY
            )
            return unless creation_options

            cell_type, category_code, storey = creation_options
            conversion_jobs = CellSpaceConversionJobBuilder.apply_fallback_storey(conversion_jobs, storey)
            progress_session = start_cell_space_create_progress(model, conversion_jobs.length)

            result = ProductionProgress::CellSpaceProgressContext.with(progress_session) do
              indoor_model.convert_cell_space_jobs_bulk(
                conversion_jobs,
                fallback_target: [cell_type, category_code],
                original_active_path: original_active_path,
                operation_name: 'Convert Solid Groups to CellSpace',
                activate_root_context: true
              )
            end
            finish_cell_space_create_progress(progress_session, result)
            close_cell_space_create_progress(progress_session)
            progress_session = nil
            publish_cell_space_command_result(result)
          rescue StandardError => e
            fail_cell_space_create_progress(progress_session, e)
            close_cell_space_create_progress(progress_session)
            progress_session = nil
            if model && defined?(original_active_path) && original_active_path
              IndoorModel.current.with_active_path_enforcement_suspended do
                restore_active_path(model, original_active_path)
              end
            end
            UiFeedback.notify("CellSpace conversion failed:\n#{e.message}")
          ensure
            close_cell_space_create_progress(progress_session)
          end
        end

        # Optional command. It intentionally is not connected to the
        # existing menu command so the current CellSpace creation path stays intact.
        def convert_selected_solid_groups_to_cell_spaces_local_grid
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

          begin
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
              return
            end

            targets = conversion_jobs.map { |job| job[:target] }.compact.uniq
            storeys = conversion_jobs.map { |job| job[:storey].to_s }.reject(&:empty?).uniq
            creation_options = prompt_cell_space_creation_options(
              'Convert Solid Groups to CellSpace Local Grid',
              default_target: targets.length == 1 ? targets.first : nil,
              default_storey: storeys.length == 1 ? storeys.first : CellSpace::DEFAULT_STOREY
            )
            return unless creation_options

            cell_type, category_code, storey = creation_options
            conversion_jobs = CellSpaceConversionJobBuilder.apply_fallback_storey(conversion_jobs, storey)

            result = indoor_model.convert_cell_space_jobs_bulk_local_grid(
              conversion_jobs,
              fallback_target: [cell_type, category_code],
              original_active_path: original_active_path,
              operation_name: 'Convert Solid Groups to CellSpace Local Grid',
              activate_root_context: true
            )
            publish_cell_space_command_result(result)
          rescue StandardError => e
            if model && defined?(original_active_path) && original_active_path
              IndoorModel.current.with_active_path_enforcement_suspended do
                restore_active_path(model, original_active_path)
              end
            end
            UiFeedback.notify("CellSpace Local Grid conversion failed:\n#{e.message}")
          end
        end

        def change_selected_cell_space_type
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

          model = Sketchup.active_model
          groups = model.selection.to_a.select { |entity| convertible_container?(entity) }

          if groups.empty?
            UiFeedback.notify('Select one or more CellSpace groups to change type.')
            return
          end

          cell_space_groups = groups.select { |group| indoor_feature(group) == 'CellSpace' }
          if cell_space_groups.empty?
            UiFeedback.notify('Select one or more CellSpace groups to change type.')
            return
          end

          unless cell_space_type_change_available?(cell_space_groups)
            UiFeedback.notify('Selected CellSpace type is locked by Tag and already matches the mapped type.')
            return
          end

          cell_type, category_code = prompt_cell_space_type_and_category('Change CellSpace Type')
          return if cell_type.nil?

          indoor_model = IndoorModel.current
          changed = indoor_model.change_cell_space_types(
            cell_space_groups,
            cell_type,
            category_code,
            operation_name: 'Change CellSpace Type'
          )
          UiFeedback.notify("Changed #{changed.length} CellSpace type(s).")
        rescue StandardError => e
          UiFeedback.notify("CellSpace type change failed:\n#{e.message}")
        end

        def vertex_normalize_context_target?
          !selected_vertex_normalize_cell_space.nil?
        rescue StandardError
          false
        end

        def vertex_normalize_selected_cell_space
          return if respond_to?(:validation_operation_running?) && validation_operation_running?
          return if @vertex_normalize_running == true

          indoor_model = IndoorModel.current
          cell_space = selected_vertex_normalize_cell_space(indoor_model)
          unless cell_space
            UiFeedback.notify('Select exactly one CellSpace to run Vertex Normalize.')
            return nil
          end

          @vertex_normalize_running = true
          progress_session = start_vertex_normalize_progress(cell_space)
          adapter = CellSpaceVertexNormalizeProgressAdapter.new(progress_session)
          tracker = PrecisionValidation::LvnProgressTracker.new(adapter)
          report = PrecisionValidation::LvnProgressContext.with(tracker) do
            indoor_model.local_vertex_normalize(cell_spaces: [cell_space])
          end

          complete_vertex_normalize_progress(progress_session, cell_space, report)
          UiFeedback.notify(vertex_normalize_result_message(cell_space, report))
          report
        rescue StandardError => error
          fail_vertex_normalize_progress(progress_session, error)
          UiFeedback.notify("Vertex Normalize failed:\n#{error.message}")
          nil
        ensure
          close_vertex_normalize_progress(progress_session)
          @vertex_normalize_running = false
        end

        private

        def selected_vertex_normalize_cell_space(indoor_model = IndoorModel.current)
          model = Sketchup.active_model
          selection = model&.selection
          entities = selection ? selection.to_a : []
          return nil unless entities.length == 1

          entity = entities.first
          return nil unless entity&.valid?
          return nil unless indoor_feature(entity) == 'CellSpace'

          cell_space = indoor_model.find_cell_space_for_entity(entity)
          cell_space if cell_space&.valid?
        rescue StandardError
          nil
        end

        def start_vertex_normalize_progress(cell_space)
          model = Sketchup.active_model
          session = ProductionProgress::ProductionProgressSession.new(
            title: 'Vertex Normalize',
            total: 100,
            renderer: ProductionProgress::SketchupOverlayProgressRenderer.new(model: model),
            cancellable: false,
            metadata: {
              operation: :cell_space_vertex_normalize,
              cell_space_id: cell_space.id
            }
          )
          session.start(message: "Preparing Vertex Normalize - #{cell_space.id}")
          session
        rescue StandardError => error
          IndoorCore::Logger.puts(
            "[IndoorGML] Vertex Normalize progress start failed: " \
            "#{error.class}: #{error.message}"
          )
          nil
        end

        def complete_vertex_normalize_progress(session, cell_space, report)
          return unless session&.active?

          session.complete(
            message: "Vertex Normalize completed - #{cell_space.id}",
            telemetry: {
              cell_space_id: cell_space.id,
              vertex_count: report[:vertex_count].to_i,
              moved_vertex_count: report[:moved_vertex_count].to_i,
              removed_coplanar_edge_count: report[:coplanar_edge_removal_count].to_i
            }
          )
        rescue StandardError => error
          IndoorCore::Logger.puts(
            "[IndoorGML] Vertex Normalize progress completion failed: " \
            "#{error.class}: #{error.message}"
          )
          nil
        end

        def fail_vertex_normalize_progress(session, error)
          return unless session&.active?

          session.fail(error, message: "Vertex Normalize failed - #{error.message}")
        rescue StandardError => progress_error
          IndoorCore::Logger.puts(
            "[IndoorGML] Vertex Normalize progress failure failed: " \
            "#{progress_error.class}: #{progress_error.message}"
          )
          nil
        end

        def close_vertex_normalize_progress(session)
          session&.close
        rescue StandardError => error
          IndoorCore::Logger.puts(
            "[IndoorGML] Vertex Normalize progress close failed: " \
            "#{error.class}: #{error.message}"
          )
          false
        end

        def vertex_normalize_result_message(cell_space, report)
          "Vertex Normalize completed for #{cell_space.id}.\n" \
            "Vertices: #{report[:vertex_count].to_i}\n" \
            "Moved vertices: #{report[:moved_vertex_count].to_i}\n" \
            "Removed coplanar edges: #{report[:coplanar_edge_removal_count].to_i}"
        end

        def start_cell_space_create_progress(model, job_count)
          session = ProductionProgress::ProductionProgressSession.new(
            title: 'CellSpace 생성',
            total: job_count,
            renderer: ProductionProgress::SketchupOverlayProgressRenderer.new(model: model),
            cancellable: false,
            metadata: {
              operation: :cell_space_create,
              job_count: job_count
            }
          )
          session.start(message: "CellSpace 생성 준비: #{job_count}개")
          session
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] CellSpace progress start failed: #{e.class}: #{e.message}"
          nil
        end

        def finish_cell_space_create_progress(session, result)
          return unless session&.active?

          converted_count = result.converted_count.to_i
          error_count = Array(result.errors).length
          session.complete(
            message: "CellSpace 생성 완료: #{converted_count}개",
            telemetry: {
              converted_count: converted_count,
              error_count: error_count,
              metrics: result.metrics || {}
            }
          )
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] CellSpace progress completion failed: #{e.class}: #{e.message}"
          nil
        end

        def fail_cell_space_create_progress(session, error)
          return unless session&.active?

          session.fail(error, message: "CellSpace 생성 실패: #{error.message}")
        rescue StandardError => progress_error
          IndoorCore::Logger.puts(
            "[IndoorGML] CellSpace progress failure reporting failed: " \
            "#{progress_error.class}: #{progress_error.message}"
          )
          nil
        end

        def close_cell_space_create_progress(session)
          session&.close
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] CellSpace progress close failed: #{e.class}: #{e.message}"
          false
        end

        def publish_cell_space_command_result(result)
          message = ConversionMessageFormatter.result_message(
            result.converted_count,
            result.errors
          )

          metrics = result.metrics || {}
          if metrics[:total_duration]
            message << "\n\n----------------------------------------"
            message << "\nCreate CellSpace 시간 요약"
            message << format(
              "\n  시작 전 검사                : %.3f sec",
              metrics[:preflight_duration].to_f
            )
            message << format(
              "\n  CellSpace/State 생성       : %.3f sec",
              metrics[:cell_space_state_duration].to_f
            )
            message << format(
              "\n  Adjacency/Transition 생성  : %.3f sec",
              metrics[:adjacency_transition_duration].to_f
            )
            message << format(
              "\n  전체 시간                   : %.3f sec",
              metrics[:total_duration].to_f
            )
            message << "\n----------------------------------------"
          end

          UiFeedback.publish_result(message, errors: result.errors)
        end
      end
    end
  end
end
