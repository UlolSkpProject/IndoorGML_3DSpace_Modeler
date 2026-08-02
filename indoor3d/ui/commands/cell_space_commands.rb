# frozen_string_literal: true

require_relative '../ui_feedback'
require_relative '../../application/progress/production_progress_session'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class SketchupStatusProgressRenderer
          def initialize(prefix: 'IndoorGML')
            @prefix = prefix.to_s
            @closed = false
          end

          def show(snapshot)
            render(snapshot)
          end

          def update(snapshot)
            render(snapshot)
          end

          def hide(_snapshot = nil)
            set_status_text('')
          end

          def close
            return false if @closed

            @closed = true
            set_status_text('')
            true
          end

          private

          def render(snapshot)
            stage = snapshot[:stage]
            percent = stage ? stage[:percent].to_f : snapshot[:percent].to_f
            message = snapshot[:message].to_s.strip
            message = snapshot[:title].to_s if message.empty?
            set_status_text(format('%s — %s (%.1f%%)', @prefix, message, percent))
          end

          def set_status_text(text)
            if Sketchup.respond_to?(:status_text=)
              Sketchup.status_text = text
            elsif Sketchup.respond_to?(:set_status_text)
              Sketchup.set_status_text(text)
            end
            true
          rescue StandardError
            false
          end
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
            progress_session = start_cell_space_create_progress(conversion_jobs.length)

            result = indoor_model.convert_cell_space_jobs_bulk(
              conversion_jobs,
              fallback_target: [cell_type, category_code],
              original_active_path: original_active_path,
              operation_name: 'Convert Solid Groups to CellSpace',
              activate_root_context: true
            )
            finish_cell_space_create_progress(progress_session, result)
            publish_cell_space_command_result(result)
          rescue StandardError => e
            fail_cell_space_create_progress(progress_session, e)
            if model && defined?(original_active_path) && original_active_path
              IndoorModel.current.with_active_path_enforcement_suspended do
                restore_active_path(model, original_active_path)
              end
            end
            UiFeedback.notify("CellSpace conversion failed:\n#{e.message}")
          ensure
            progress_session&.close
          end
        end

        # Experimental opt-in command. It intentionally is not connected to the
        # existing menu command so the current CellSpace creation path stays intact.
        def convert_selected_solid_groups_to_cell_spaces_local_grid_v2
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
              'Convert Solid Groups to CellSpace Local Grid V2',
              default_target: targets.length == 1 ? targets.first : nil,
              default_storey: storeys.length == 1 ? storeys.first : CellSpace::DEFAULT_STOREY
            )
            return unless creation_options

            cell_type, category_code, storey = creation_options
            conversion_jobs = CellSpaceConversionJobBuilder.apply_fallback_storey(conversion_jobs, storey)

            result = indoor_model.convert_cell_space_jobs_bulk_local_grid_v2(
              conversion_jobs,
              fallback_target: [cell_type, category_code],
              original_active_path: original_active_path,
              operation_name: 'Convert Solid Groups to CellSpace Local Grid V2',
              activate_root_context: true
            )
            publish_cell_space_command_result(result)
          rescue StandardError => e
            if model && defined?(original_active_path) && original_active_path
              IndoorModel.current.with_active_path_enforcement_suspended do
                restore_active_path(model, original_active_path)
              end
            end
            UiFeedback.notify("CellSpace Local Grid V2 conversion failed:\n#{e.message}")
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

        private

        def start_cell_space_create_progress(job_count)
          session = ProductionProgress::ProductionProgressSession.new(
            title: 'CellSpace 생성',
            total: job_count,
            renderer: ProductionProgress::SketchupStatusProgressRenderer.new,
            cancellable: false,
            metadata: {
              operation: :cell_space_create,
              job_count: job_count
            }
          )
          session.start(message: "CellSpace 생성 준비: #{job_count}개")
          session.start_stage(
            'cell_space_create',
            total: job_count,
            message: "CellSpace 생성 중: #{job_count}개",
            cancellable: false
          )
          session
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] CellSpace progress start failed: #{e.class}: #{e.message}"
          nil
        end

        def finish_cell_space_create_progress(session, result)
          return unless session&.active?

          converted_count = result.converted_count.to_i
          error_count = Array(result.errors).length
          session.update_stage(
            completed: converted_count,
            message: "CellSpace 생성 결과: #{converted_count}개, 오류 #{error_count}개"
          )
          session.finish_stage(
            message: "CellSpace 생성 완료: #{converted_count}개",
            telemetry: {
              converted_count: converted_count,
              error_count: error_count
            }
          )
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
