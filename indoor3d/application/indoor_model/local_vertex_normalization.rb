# frozen_string_literal: true

require_relative '../local_vertex_normalizer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        # IndoorModel integration for LocalVertexNormalizer.
        #
        # Default behavior preserves the current SketchUp edit context. Geometry
        # is normalized through group.definition.entities, so entering the target
        # CellSpace edit path is not required.
        module LocalVertexNormalization
          def is_vertex_locally_normalized?(
            target = nil,
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
          )
            if target.is_a?(Numeric)
              tolerance_mm = target
              target = nil
            end

            targets = if target.nil?
                        valid_local_normalization_cell_spaces
                      else
                        Array(target)
                      end
            return false if targets.empty?

            targets.all? do |candidate|
              group = local_normalization_group(candidate)
              group && LocalVertexNormalizer.normalized?(group, tolerance_mm)
            end
          end

          alias vertex_locally_normalized? is_vertex_locally_normalized?

          def locally_unnormalized_cell_spaces(
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            cell_spaces: nil
          )
            normalization_targets(cell_spaces).reject do |cell_space|
              group = local_normalization_group(cell_space)
              group && LocalVertexNormalizer.normalized?(group, tolerance_mm)
            end
          end

          # Export guard. Only CellSpaces that fail the fast normalized? predicate
          # are rebuilt.
          #
          # activate_edit_context defaults to false. In that mode this module does
          # not enter or leave edit mode and works directly on each definition.
          def ensure_vertices_locally_normalized_for_export(
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            cell_spaces: nil,
            activate_edit_context: false,
            debug: false,
            report: false,
            report_path: nil
          )
            targets = normalization_targets(cell_spaces)
            unnormalized = locally_unnormalized_cell_spaces(
              tolerance_mm,
              cell_spaces: targets
            )

            if unnormalized.empty?
              empty_report = empty_local_normalization_report(
                tolerance_mm,
                already_normalized_cell_space_count: targets.length,
                skipped: true,
                activate_edit_context: activate_edit_context
              )
              if report == true
                timing_profile = {
                  enabled: true,
                  status: :success,
                  total_seconds: 0.0,
                  operation_total_seconds: 0.0,
                  operation_body_seconds: 0.0,
                  operation_boundary_overhead_seconds: 0.0,
                  topology_sync_seconds: 0.0,
                  cell_spaces: []
                }
                written_path = write_local_normalization_timing_report(
                  timing_profile,
                  normalization_report: empty_report,
                  targets: targets,
                  report_path: report_path
                )
                empty_report[:debug_profile] = timing_profile
                empty_report[:timing_report_path] = written_path
                puts "[LVN REPORT] SUCCESS total=0.000000s path=#{written_path}"
              end
              return empty_report
            end

            # Preserve compatibility with test doubles and older overrides that do
            # not accept activate_edit_context when the default mode is used.
            normalization_options = { cell_spaces: unnormalized }
            normalization_options[:activate_edit_context] = true if activate_edit_context
            normalization_options[:debug] = true if debug == true
            normalization_options[:report] = true if report == true
            normalization_options[:report_path] = report_path if report_path
            normalization_report = local_vertex_normalize(
              tolerance_mm,
              **normalization_options
            )

            normalization_report[:already_normalized_cell_space_count] =
              targets.length - unnormalized.length
            normalization_report[:skipped] = false
            normalization_report
          end

          # Normalizes selected CellSpaces in one SketchUp operation.
          #
          # When activate_edit_context is false, the active edit path is never
          # read, changed, closed, or restored by this module.
          #
          # When activate_edit_context is true, each target CellSpace is activated
          # temporarily and the previous path is restored afterward. This mode is
          # retained only for callers that explicitly require the old behavior.
          def local_vertex_normalize(
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            cell_spaces: nil,
            activate_edit_context: false,
            debug: false,
            report: false,
            report_path: nil
          )
            report_requested = report == true
            verbose_debug = debug == true && !report_requested
            results = []
            topology_metrics = nil
            topology_sync_seconds = 0.0
            operation_body_seconds = 0.0
            batch_started_at = local_normalization_monotonic_time
            operation_body_started_at = nil
            topology_started_at = nil
            operation_started_at = nil
            operation_total_seconds = 0.0
            LocalVertexNormalizer.last_debug_profile = nil if report_requested
            targets = normalization_targets(cell_spaces)
            if targets.empty?
              raise 'No valid CellSpace found for local vertex normalization'
            end

            puts "[LVN DEBUG] BATCH START cells=#{targets.length}" if verbose_debug

            operation_started_at = local_normalization_monotonic_time
            with_indoor_model_operation('IndoorGML Local Vertex Normalize') do
              operation_body_started_at = local_normalization_monotonic_time
              sync do
                targets.each do |cell_space|
                  group = cell_space.valid_sketchup_group
                  unless group
                    raise "CellSpace geometry unavailable: #{cell_space.id}"
                  end

                  result = normalize_cell_space_group(
                    cell_space,
                    group,
                    tolerance_mm,
                    activate_edit_context: activate_edit_context,
                    debug: debug,
                    report: report_requested
                  )

                  result[:cell_space_id] = cell_space.id
                  results << result
                  remember_cell_space_change_snapshot(cell_space.sketchup_group)
                end

                topology_started_at = local_normalization_monotonic_time
                puts '[LVN DEBUG] BATCH START topology_synchronize_all' if verbose_debug
                topology_metrics = topology_coordinator.synchronize_all
                topology_sync_seconds =
                  local_normalization_monotonic_time - topology_started_at
                if verbose_debug
                  puts format(
                    '[LVN DEBUG] BATCH END   topology_synchronize_all duration=%.6fs',
                    topology_sync_seconds
                  )
                end
              end
              operation_body_seconds =
                local_normalization_monotonic_time - operation_body_started_at
            end
            operation_total_seconds =
              local_normalization_monotonic_time - operation_started_at

            invalidate_overlay_transition_points
            model = @model || Sketchup.active_model
            model.active_view.invalidate if model&.active_view

            normalization_report = aggregate_local_normalization_report(
              tolerance_mm,
              results,
              topology_metrics,
              activate_edit_context: activate_edit_context
            )
            if debug == true || report_requested
              total_seconds = local_normalization_monotonic_time - batch_started_at
              timing_profile = {
                enabled: true,
                status: :success,
                total_seconds: total_seconds,
                operation_total_seconds: operation_total_seconds,
                operation_body_seconds: operation_body_seconds,
                operation_boundary_overhead_seconds:
                  operation_total_seconds - operation_body_seconds,
                topology_sync_seconds: topology_sync_seconds,
                cell_spaces: results.filter_map { |result| result[:debug_profile] }
              }
              normalization_report[:debug_profile] = timing_profile
              if report_requested
                written_path = write_local_normalization_timing_report(
                  timing_profile,
                  normalization_report: normalization_report,
                  targets: targets,
                  report_path: report_path
                )
                normalization_report[:timing_report_path] = written_path
                puts format(
                  '[LVN REPORT] SUCCESS total=%.6fs path=%s',
                  total_seconds,
                  written_path
                )
              else
                puts format(
                  '[LVN DEBUG] BATCH END total=%.6fs operation=%.6fs ' \
                  'operation_boundary=%.6fs topology_sync=%.6fs',
                  total_seconds,
                  operation_total_seconds,
                  operation_total_seconds - operation_body_seconds,
                  topology_sync_seconds
                )
              end
            end
            log_local_normalization_report(normalization_report) unless report_requested
            normalization_report
          rescue StandardError => error
            if defined?(report_requested) && report_requested
              begin
                now = local_normalization_monotonic_time
                operation_total_seconds = now - operation_started_at if operation_started_at
                if operation_body_started_at && operation_body_seconds.zero?
                  operation_body_seconds = now - operation_body_started_at
                end
                if topology_started_at && topology_sync_seconds.zero?
                  topology_sync_seconds = now - topology_started_at
                end
                profiles = Array(results).filter_map { |result| result[:debug_profile] }
                failed_profile = LocalVertexNormalizer.last_debug_profile
                profiles << failed_profile if failed_profile && !profiles.include?(failed_profile)
                timing_profile = {
                  enabled: true,
                  status: :failed,
                  error: "#{error.class}: #{error.message}",
                  total_seconds: now - batch_started_at,
                  operation_total_seconds: operation_total_seconds,
                  operation_body_seconds: operation_body_seconds,
                  operation_boundary_overhead_seconds:
                    operation_total_seconds - operation_body_seconds,
                  topology_sync_seconds: topology_sync_seconds,
                  cell_spaces: profiles
                }
                written_path = write_local_normalization_timing_report(
                  timing_profile,
                  normalization_report: nil,
                  targets: targets,
                  report_path: report_path
                )
                puts format(
                  '[LVN REPORT] FAILED total=%.6fs path=%s',
                  timing_profile[:total_seconds],
                  written_path
                )
              rescue StandardError => report_error
                puts "[LVN REPORT] WRITE FAILED #{report_error.class}: #{report_error.message}"
              end
            end
            raise
          end

          private

          def normalization_targets(cell_spaces)
            source = cell_spaces.nil? ? valid_local_normalization_cell_spaces : Array(cell_spaces)
            source.select { |cell_space| cell_space&.valid? }
          end

          def valid_local_normalization_cell_spaces
            Array(@cell_spaces).select { |cell_space| cell_space&.valid? }
          end

          def local_normalization_group(candidate)
            if candidate.respond_to?(:valid_sketchup_group)
              candidate.valid_sketchup_group
            elsif candidate.respond_to?(:definition)
              candidate
            end
          rescue StandardError
            nil
          end

          def normalize_cell_space_group(
            cell_space,
            group,
            tolerance_mm,
            activate_edit_context:,
            debug: false,
            report: false
          )
            with_unlocked(group) do
              runner = proc do
                # The surrounding batch owns one atomic SketchUp operation.
                # Opening another operation for every Solid can leave dialog and
                # observer state unresponsive after the batch commit.
                normalization_options = {
                  debug: debug,
                  manage_operation: false
                }
                if report == true
                  normalization_options[:report] = true
                  normalization_options[:write_report] = false
                end
                LocalVertexNormalizer.normalize(
                  group,
                  tolerance_mm,
                  **normalization_options
                )
              rescue StandardError => e
                name = group.respond_to?(:name) ? group.name.inspect : 'n/a'
                raise e.class,
                      "CellSpace local vertex normalization failed: " \
                      "id=#{cell_space.id.inspect} name=#{name}: #{e.message}",
                      e.backtrace
              end

              if activate_edit_context
                with_local_normalization_active_path(group) { runner.call }
              else
                runner.call
              end
            end
          end

          # Legacy opt-in path activation. Default normalization never calls this.
          def with_local_normalization_active_path(group)
            model = @model || Sketchup.active_model
            return yield unless model&.respond_to?(:active_path=)

            controller = ActivePathController.new(
              model,
              logger: IndoorCore::Logger
            )
            previous_path = controller.snapshot
            target_path = []
            target_path << @primal_group if @primal_group&.valid?
            target_path << group

            runner = proc do
              unless controller.set(target_path)
                label = group.respond_to?(:name) ? group.name : group
                raise "Could not activate CellSpace edit context: #{label}"
              end

              yield
            ensure
              controller.restore(previous_path, close_when_nil: true)
            end

            if respond_to?(:with_active_path_enforcement_suspended)
              with_active_path_enforcement_suspended { runner.call }
            else
              runner.call
            end
          end

          def empty_local_normalization_report(
            tolerance_mm,
            already_normalized_cell_space_count:,
            skipped:,
            activate_edit_context:
          )
            {
              tolerance_mm: Float(tolerance_mm),
              cell_space_count: 0,
              already_normalized_cell_space_count: already_normalized_cell_space_count,
              skipped: skipped,
              activate_edit_context: activate_edit_context,
              edit_context_strategy: activate_edit_context ? :target : :preserve,
              vertex_count: 0,
              moved_vertex_count: 0,
              max_displacement_mm: 0.0,
              max_grid_residual_mm: 0.0,
              max_unprotected_grid_residual_mm: 0.0,
              protected_coincident_vertex_count: 0,
              incomplete_cell_space_count: 0,
              max_normalization_passes: 0,
              source_triangle_count: 0,
              added_face_count: 0,
              skipped_collinear_triangle_count: 0,
              surface_border_repair_count: 0,
              strict_coplanar_edge_removal_count: 0,
              coplanar_edge_removal_count: 0,
              collinear_vertex_removal_count: 0,
              reoriented_face_count: 0,
              total_volume_delta_mm3: 0.0,
              topology_metrics: nil,
              cell_spaces: []
            }
          end

          def aggregate_local_normalization_report(
            tolerance_mm,
            results,
            topology_metrics,
            activate_edit_context:
          )
            {
              tolerance_mm: Float(tolerance_mm),
              cell_space_count: results.length,
              already_normalized_cell_space_count: 0,
              skipped: false,
              activate_edit_context: activate_edit_context,
              edit_context_strategy: activate_edit_context ? :target : :preserve,
              vertex_count: sum_report_value(results, :vertex_count),
              moved_vertex_count: sum_report_value(results, :moved_vertex_count),
              max_displacement_mm: max_report_value(results, :max_displacement_mm),
              max_grid_residual_mm: max_report_value(results, :max_grid_residual_mm),
              max_unprotected_grid_residual_mm: max_report_value(
                results,
                :max_unprotected_grid_residual_mm
              ),
              protected_coincident_vertex_count: sum_report_value(
                results,
                :protected_coincident_vertex_count
              ),
              incomplete_cell_space_count: results.count do |row|
                row[:normalization_complete] == false
              end,
              max_normalization_passes: results.map do |row|
                Array(row[:normalization_passes]).length
              end.max || 0,
              source_triangle_count: sum_report_value(results, :source_triangle_count),
              added_face_count: sum_report_value(results, :added_face_count),
              skipped_collinear_triangle_count: sum_report_value(
                results,
                :skipped_collinear_triangle_count
              ),
              surface_border_repair_count: sum_report_value(
                results,
                :surface_border_repair_count
              ),
              strict_coplanar_edge_removal_count: sum_report_value(
                results,
                :strict_coplanar_edge_removal_count
              ),
              coplanar_edge_removal_count: sum_report_value(
                results,
                :coplanar_edge_removal_count
              ),
              collinear_vertex_removal_count: sum_report_value(
                results,
                :collinear_vertex_removal_count
              ),
              reoriented_face_count: sum_report_value(
                results,
                :reoriented_face_count
              ),
              total_volume_delta_mm3: results.sum do |row|
                row[:volume_after_mm3].to_f - row[:volume_before_mm3].to_f
              end,
              topology_metrics: topology_metrics,
              cell_spaces: results
            }
          end

          def sum_report_value(results, key)
            results.sum { |row| row[key].to_i }
          end

          def max_report_value(results, key)
            results.map { |row| row[key].to_f }.max || 0.0
          end

          def write_local_normalization_timing_report(
            timing_profile,
            normalization_report:,
            targets:,
            report_path:
          )
            solid_profiles = Array(timing_profile[:cell_spaces])
            payload = {
              schema: 'ulol.local_vertex_normalization.timing.v1',
              generated_at: Time.now.iso8601(3),
              scope: 'batch',
              timing_semantics: 'inclusive; nested stage totals are not additive',
              status: timing_profile[:status],
              total_seconds: timing_profile[:total_seconds],
              operation: {
                total_seconds: timing_profile[:operation_total_seconds],
                body_seconds: timing_profile[:operation_body_seconds],
                boundary_overhead_seconds:
                  timing_profile[:operation_boundary_overhead_seconds]
              },
              topology_sync_seconds: timing_profile[:topology_sync_seconds],
              error: timing_profile[:error],
              geometry_totals: {
                before: sum_profile_geometry_counts(solid_profiles, :geometry_before),
                after: sum_profile_geometry_counts(solid_profiles, :geometry_after)
              },
              stage_totals: aggregate_profile_stage_timings(solid_profiles),
              snapshot_role_totals:
                aggregate_profile_snapshot_role_timings(solid_profiles),
              normalization_summary:
                compact_normalization_summary(normalization_report),
              solids: solid_profiles
            }
            first_group = Array(targets).filter_map do |cell_space|
              cell_space.valid_sketchup_group if
                cell_space.respond_to?(:valid_sketchup_group)
            end.first
            LocalVertexNormalizer.write_timing_report(
              payload,
              report_path: report_path,
              entity: first_group,
              prefix: 'local_vertex_normalization_batch'
            )
          end

          def sum_profile_geometry_counts(profiles, key)
            fields = [:faces, :edges, :vertices, :boundary_edges,
                      :wire_edges, :overused_edges, :volume_mm3]
            fields.to_h do |field|
              total = if field == :volume_mm3
                        profiles.sum { |profile| profile.dig(key, field).to_f }
                      else
                        profiles.sum { |profile| profile.dig(key, field).to_i }
                      end
              [field, total]
            end
          end

          def aggregate_profile_stage_timings(profiles)
            totals = {}
            profiles.each do |profile|
              Hash(profile[:stages]).each do |name, metrics|
                entry = totals[name] ||= {
                  calls: 0,
                  total_seconds: 0.0,
                  max_seconds: 0.0,
                  failures: 0
                }
                entry[:calls] += metrics[:calls].to_i
                entry[:total_seconds] += metrics[:total_seconds].to_f
                entry[:max_seconds] = [
                  entry[:max_seconds],
                  metrics[:max_seconds].to_f
                ].max
                entry[:failures] += metrics[:failures].to_i
              end
            end
            totals.sort_by { |_name, metrics| -metrics[:total_seconds] }.to_h
          end

          def aggregate_profile_snapshot_role_timings(profiles)
            totals = {}
            profiles.each do |profile|
              Hash(profile[:snapshot_roles]).each do |role, metrics|
                entry = totals[role] ||= {
                  calls: 0,
                  total_seconds: 0.0,
                  max_seconds: 0.0,
                  failures: 0
                }
                entry[:calls] += metrics[:calls].to_i
                entry[:total_seconds] += metrics[:total_seconds].to_f
                entry[:max_seconds] = [
                  entry[:max_seconds],
                  metrics[:max_seconds].to_f
                ].max
                entry[:failures] += metrics[:failures].to_i
              end
            end
            totals.sort_by { |_role, metrics| -metrics[:total_seconds] }.to_h
          end

          def compact_normalization_summary(report)
            return nil unless report

            report.reject do |key, _value|
              [:cell_spaces, :debug_profile].include?(key)
            end
          end

          def log_local_normalization_report(report)
            IndoorCore::Logger.puts(
              "[IndoorGML] Local vertex normalize: " \
              "tolerance=#{report[:tolerance_mm]}mm " \
              "cells=#{report[:cell_space_count]} " \
              "vertices=#{report[:vertex_count]} " \
              "moved=#{report[:moved_vertex_count]} " \
              "max_displacement=#{report[:max_displacement_mm]}mm " \
              "edit_context=#{report[:edit_context_strategy]}"
            )
          end

          def local_normalization_monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
      end
    end
  end
end
