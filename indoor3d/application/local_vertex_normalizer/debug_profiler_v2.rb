# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'
require 'time'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Optional timing instrumentation for the production normalization path.
      # It never changes geometry decisions and is completely inactive unless
      # normalize is called with debug: true or report: true.
      module LocalVertexNormalizerDebugProfilerV2
        def normalize(
          entity,
          commit_on_failure: false,
          debug: false,
          report: false,
          report_path: nil,
          write_report: true,
          manage_operation: true,
          **options
        )
          profiling_enabled = debug == true || report == true
          return super(
            entity,
            commit_on_failure: commit_on_failure,
            manage_operation: manage_operation,
            **options
          ) unless profiling_enabled

          start_debug_profile(
            entity,
            verbose: debug == true && report != true,
            report_enabled: report == true
          )
          begin
            result = super(
              entity,
              commit_on_failure: commit_on_failure,
              manage_operation: manage_operation,
              **options
            )
            profile = finish_debug_profile(:success)
            if report == true && write_report
              written_path = self.class.write_timing_report(
                single_solid_timing_report(profile),
                report_path: report_path,
                entity: entity,
                prefix: 'local_vertex_normalization'
              )
              profile[:report_path] = written_path
              puts format(
                '[LVN REPORT] SUCCESS total=%.6fs path=%s',
                profile[:total_seconds],
                written_path
              )
            end
            result[:debug_profile] = profile if result.is_a?(Hash)
            result[:timing_report_path] = profile[:report_path] if
              result.is_a?(Hash) && profile[:report_path]
            result
          rescue StandardError => error
            profile = finish_debug_profile(:failed, error: error)
            if report == true && write_report
              begin
                written_path = self.class.write_timing_report(
                  single_solid_timing_report(profile),
                  report_path: report_path,
                  entity: entity,
                  prefix: 'local_vertex_normalization'
                )
                profile[:report_path] = written_path
                puts format(
                  '[LVN REPORT] FAILED total=%.6fs path=%s',
                  profile[:total_seconds],
                  written_path
                )
              rescue StandardError => report_error
                puts "[LVN REPORT] WRITE FAILED #{report_error.class}: #{report_error.message}"
              end
            end
            raise
          ensure
            @local_vertex_normalizer_debug_profile = nil
            @local_vertex_normalizer_debug_entity = nil
          end
        end

        def debug_profile
          @local_vertex_normalizer_debug_profile ||
            @local_vertex_normalizer_last_debug_profile
        end

        private

        def validate_entity!(entity)
          measure_debug_stage(:source_entity_validation) { super }
        end

        def with_normalization_operation(entity, commit_on_failure: false, &block)
          measure_debug_stage(:operation_total) do
            super(entity, commit_on_failure: commit_on_failure, &block)
          end
        end

        def normalize_entity(entity)
          measure_debug_stage(:normalize_entity_total) { super }
        end

        def ensure_unique_definition(entity)
          measure_debug_stage(:unique_definition_check) { super }
        end

        def axis_plane_normalization_plan(entities)
          measure_debug_stage(:axis_plane_plan, entity_count: debug_collection_size(entities)) do
            super
          end
        end

        def normalized_vertex_metrics(vertices, axis_plane_plan = nil)
          measure_debug_stage(:vertex_target_metrics, vertex_count: vertices.length) do
            super
          end
        end

        def short_edge_sliver_collapse_plan(entities, axis_plane_plan = nil)
          measure_debug_stage(:short_edge_sliver_plan) { super }
        end

        def triangle_snapshot(entities)
          measure_debug_stage(:source_brep_snapshot) { super }
        end

        def conforming_triangle_snapshot(source_triangles, coordinate_space: :grid)
          measure_debug_stage(
            "conforming_#{coordinate_space}".to_sym,
            triangle_count: source_triangles.length
          ) do
            super
          end
        end

        def repair_degenerate_source_triangles(triangle_records, coordinate_space: :grid)
          measure_debug_stage(
            "degenerate_repair_#{coordinate_space}".to_sym,
            triangle_count: triangle_records.length
          ) do
            super
          end
        end

        def normalize_triangle_records_allowing_collisions(
          triangle_records,
          axis_plane_plan = nil,
          duplicate_diagnostics: nil
        )
          measure_debug_stage(
            :grid_target_projection,
            triangle_count: triangle_records.length
          ) do
            super
          end
        end

        def repair_grid_triangles_with_patch_fallback(triangle_records)
          measure_debug_stage(
            :grid_triangle_repair,
            triangle_count: triangle_records.length
          ) do
            super
          end
        end

        def validate_normalized_triangle_shapes!(triangle_records)
          measure_debug_stage(
            :triangle_shape_validation,
            triangle_count: triangle_records.length
          ) do
            super
          end
        end

        def triangle_mesh_inventory(triangle_records)
          measure_debug_stage(
            :triangle_mesh_inventory,
            triangle_count: triangle_records.length
          ) do
            super
          end
        end

        def collapse_short_edge_sliver_triangles(triangle_records, plan, baseline_inventory)
          measure_debug_stage(
            :short_edge_sliver_collapse,
            triangle_count: triangle_records.length
          ) do
            super
          end
        end

        def sanitize_triangle_records(triangle_records, **options)
          measure_debug_stage(
            :triangle_record_sanitize,
            triangle_count: triangle_records.length
          ) do
            super
          end
        end

        def collect_forced_retriangulation_keys(*reports)
          measure_debug_stage(
            :forced_retriangulation_collection,
            report_count: reports.length
          ) do
            super
          end
        end

        def retriangulate_exact_coplanar_patches(
          triangle_records,
          forced_source_face_keys: [],
          force_all: false
        )
          measure_debug_stage(
            :exact_coplanar_patch_retriangulation,
            triangle_count: triangle_records.length,
            forced_face_count: forced_source_face_keys.length
          ) do
            super
          end
        end

        def validate_normalized_triangle_mesh!(triangle_records)
          measure_debug_stage(
            :closed_mesh_and_intersection_validation,
            triangle_count: triangle_records.length,
            possible_pair_count: debug_possible_pair_count(triangle_records.length)
          ) do
            super
          end
        end

        def validate_sliver_topology_when_comparable!(before, after, repair_report)
          measure_debug_stage(:sliver_topology_validation) { super }
        end

        def validate_triangle_intersections!(triangles)
          measure_debug_stage(
            :triangle_intersection_validation,
            {
              triangle_count: triangles.length,
              possible_pair_count: debug_possible_pair_count(triangles.length)
            },
            emit: triangles.length > 20
          ) do
            super
          end
        end

        def erase_source_geometry(entities)
          measure_debug_stage(:erase_source_geometry) { super }
        end

        def rebuild_triangles(entities, triangle_records)
          measure_debug_stage(
            :sketchup_face_rebuild,
            triangle_count: triangle_records.length
          ) do
            super
          end
        end

        def normalized_triangle_snapshot(
          entities,
          axis_plane_plan = nil,
          duplicate_diagnostics: nil
        )
          measure_debug_stage(:rebuilt_geometry_snapshot) { super }
        end

        def verify_triangle_rebuild!(expected_records, actual_records)
          measure_debug_stage(
            :triangle_rebuild_validation,
            expected_triangle_count: expected_records.length,
            actual_triangle_count: actual_records.length
          ) do
            super
          end
        end

        def orient_and_merge_rebuilt_surface(entities, validated_triangles)
          measure_debug_stage(
            :orient_and_coplanar_cleanup,
            triangle_count: validated_triangles.length
          ) do
            super
          end
        end

        def remove_coplanar_shared_edges(
          entities,
          plane_tolerance_mm:,
          angle_tolerance_deg:
        )
          measure_debug_stage(
            :coplanar_shared_edge_cleanup,
            plane_tolerance_mm: plane_tolerance_mm,
            angle_tolerance_deg: angle_tolerance_deg
          ) do
            super
          end
        end

        def repair_rebuilt_entity_before_rollback(entity, entities)
          measure_debug_stage(:final_entity_repair) { super }
        end

        def validate_rebuilt_entity!(entity, topology)
          measure_debug_stage(:rebuilt_entity_validation) { super }
        end

        def max_grid_residual_mm(vertices)
          measure_debug_stage(
            :final_grid_residual,
            vertex_count: vertices.length
          ) do
            super
          end
        end

        def stitch_surface_borders(entities)
          measure_debug_stage(:surface_border_repair) { super }
        end

        def remove_external_faces_conservatively(entities)
          measure_debug_stage(:external_face_repair) { super }
        end

        def normalized_surface_descriptor(triangle_records)
          measure_debug_stage(
            :surface_descriptor,
            triangle_count: triangle_records.length
          ) do
            super
          end
        end

        def verify_normalized_surface_equivalence!(expected_records, actual_records)
          measure_debug_stage(
            :surface_equivalence,
            expected_triangle_count: expected_records.length,
            actual_triangle_count: actual_records.length
          ) do
            super
          end
        end

        def aggregate_degenerate_repair_reports(stage_reports)
          measure_debug_stage(:degenerate_report_aggregation) { super }
        end

        def build_normalization_report(**options)
          measure_debug_stage(:normalization_report_build) { super }
        end

        def augment_v2_normalization_report!(report, **options)
          measure_debug_stage(:normalization_report_augmentation) { super }
        end

        def start_debug_profile(entity, verbose:, report_enabled:)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @local_vertex_normalizer_debug_entity = entity
          @local_vertex_normalizer_debug_profile = {
            enabled: true,
            verbose: verbose,
            report_enabled: report_enabled,
            entity: debug_entity_label(entity),
            persistent_id: debug_entity_persistent_id(entity),
            tolerance_mm: @tolerance_mm,
            geometry_before: debug_geometry_counts(entity),
            started_at: started_at,
            status: :running,
            depth: 0,
            events: [],
            stages: {}
          }
          if verbose
            debug_profile_log(
              "PROFILE START entity=#{debug_entity_label(entity)} " \
              "tolerance=#{@tolerance_mm}mm"
            )
          end
        end

        def finish_debug_profile(status, error: nil)
          profile = @local_vertex_normalizer_debug_profile
          return @local_vertex_normalizer_last_debug_profile unless profile

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          profile[:status] = status
          profile[:total_seconds] = now - profile[:started_at]
          profile[:error] = "#{error.class}: #{error.message}" if error
          profile[:geometry_after] = debug_geometry_counts_from_current_entity(profile)
          profile.delete(:started_at)
          profile.delete(:depth)
          @local_vertex_normalizer_last_debug_profile = profile
          self.class.last_debug_profile = profile if
            self.class.respond_to?(:last_debug_profile=)

          if profile[:verbose]
            debug_profile_log(
              format(
                'PROFILE %s total=%.6fs',
                status.to_s.upcase,
                profile[:total_seconds]
              )
            )
            profile[:stages]
              .sort_by { |_name, metrics| -metrics[:total_seconds] }
              .each do |name, metrics|
                debug_profile_log(
                  format(
                    'SUMMARY %-42s total=%10.6fs calls=%d max=%10.6fs failures=%d',
                    name,
                    metrics[:total_seconds],
                    metrics[:calls],
                    metrics[:max_seconds],
                    metrics[:failures]
                  )
                )
              end
          end
          profile
        end

        def measure_debug_stage(stage, details = nil, emit: true, **detail_keywords)
          profile = @local_vertex_normalizer_debug_profile
          return yield unless profile

          details = (details || {}).merge(detail_keywords)
          stage = stage.to_sym
          depth = profile[:depth]
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          elapsed_from_start = started_at - profile[:started_at]
          if emit && profile[:verbose]
            debug_profile_log(
              format(
                '%sSTART %-42s at=%10.6fs%s',
                '  ' * depth,
                stage,
                elapsed_from_start,
                debug_details_suffix(details)
              )
            )
          end
          profile[:depth] = depth + 1
          status = :success
          error = nil

          begin
            yield
          rescue StandardError => caught
            status = :failed
            error = caught
            raise
          ensure
            finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration = finished_at - started_at
            profile[:depth] = depth
            event = {
              stage: stage,
              status: status,
              seconds: duration,
              started_after_seconds: elapsed_from_start,
              details: details
            }
            event[:error] = "#{error.class}: #{error.message}" if error
            profile[:events] << event
            metrics = profile[:stages][stage] ||= {
              calls: 0,
              total_seconds: 0.0,
              max_seconds: 0.0,
              failures: 0
            }
            metrics[:calls] += 1
            metrics[:total_seconds] += duration
            metrics[:max_seconds] = [metrics[:max_seconds], duration].max
            metrics[:failures] += 1 if status == :failed
            if emit && profile[:verbose]
              debug_profile_log(
                format(
                  '%s%s %-42s duration=%10.6fs%s',
                  '  ' * depth,
                  status == :success ? 'END  ' : 'FAIL ',
                  stage,
                  duration,
                  error ? " error=#{error.class}: #{error.message}" : ''
                )
              )
            end
          end
        end

        def debug_entity_label(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          id = if entity.respond_to?(:persistent_id)
                 entity.persistent_id
               elsif entity.respond_to?(:entityID)
                 entity.entityID
               end
          label = name.empty? ? entity.class.to_s : name
          id ? "#{label}[PID=#{id}]" : label
        rescue StandardError
          entity.class.to_s
        end

        def debug_entity_persistent_id(entity)
          return entity.persistent_id if entity.respond_to?(:persistent_id)
          return entity.entityID if entity.respond_to?(:entityID)

          nil
        rescue StandardError
          nil
        end

        def debug_geometry_counts(entity)
          return {} unless entity&.respond_to?(:definition)

          entities = entity.definition.entities
          counts = geometry_counts(entities)
          {
            faces: counts[:faces].to_i,
            edges: counts[:edges].to_i,
            vertices: counts[:vertices].to_i,
            boundary_edges: counts[:boundary_edges].to_i,
            wire_edges: counts[:wire_edges].to_i,
            overused_edges: counts[:overused_edges].to_i,
            volume_mm3: solid_volume_mm3(entity)
          }
        rescue StandardError => error
          { error: "#{error.class}: #{error.message}" }
        end

        def debug_geometry_counts_from_current_entity(profile)
          entity = @local_vertex_normalizer_debug_entity
          entity ? debug_geometry_counts(entity) : profile[:geometry_before]
        end

        def single_solid_timing_report(profile)
          {
            schema: 'ulol.local_vertex_normalization.timing.v1',
            generated_at: Time.now.iso8601(3),
            scope: 'solid',
            timing_semantics: 'inclusive; nested stage totals are not additive',
            status: profile[:status],
            total_seconds: profile[:total_seconds],
            tolerance_mm: profile[:tolerance_mm],
            solid: profile
          }
        end

        def debug_collection_size(collection)
          collection.respond_to?(:length) ? collection.length : nil
        rescue StandardError
          nil
        end

        def debug_possible_pair_count(count)
          count = count.to_i
          count > 1 ? (count * (count - 1)) / 2 : 0
        end

        def debug_details_suffix(details)
          compact = details.reject { |_key, value| value.nil? }
          compact.empty? ? '' : " #{compact.inspect}"
        end

        def debug_profile_log(message)
          puts "[LVN DEBUG] #{message}"
        end
      end

      class LocalVertexNormalizer
        class << self
          attr_accessor :last_debug_profile

          def write_timing_report(
            payload,
            report_path: nil,
            entity: nil,
            prefix: 'local_vertex_normalization'
          )
            path = resolve_timing_report_path(
              report_path,
              entity: entity,
              prefix: prefix
            )
            FileUtils.mkdir_p(File.dirname(path))
            File.open(path, 'w:UTF-8') do |file|
              file.write(JSON.pretty_generate(payload))
              file.write("\n")
            end
            path
          end

          private

          def resolve_timing_report_path(report_path, entity:, prefix:)
            supplied = report_path.to_s.strip
            return File.expand_path(supplied) if
              !supplied.empty? && File.extname(supplied).downcase == '.json'

            directory = supplied.empty? ? default_timing_report_directory(entity) : supplied
            base_name = timing_report_model_name(entity)
            timestamp = Time.now.strftime('%Y%m%d_%H%M%S_%L')
            filename = [base_name, prefix, timestamp].reject(&:empty?).join('_') + '.json'
            File.expand_path(File.join(directory, filename))
          end

          def default_timing_report_directory(entity)
            model = entity.model if entity&.respond_to?(:model)
            model_path = model.path.to_s if model&.respond_to?(:path)
            return File.dirname(model_path) if model_path && !model_path.empty?

            Dir.tmpdir
          rescue StandardError
            Dir.tmpdir
          end

          def timing_report_model_name(entity)
            model = entity.model if entity&.respond_to?(:model)
            model_path = model.path.to_s if model&.respond_to?(:path)
            name = if model_path && !model_path.empty?
                     File.basename(model_path, File.extname(model_path))
                   else
                     'unsaved_model'
                   end
            name.gsub(/[^0-9A-Za-z가-힣._-]+/, '_')
          rescue StandardError
            'model'
          end
        end

        prepend LocalVertexNormalizerDebugProfilerV2 unless
          ancestors.include?(LocalVertexNormalizerDebugProfilerV2)
      end
    end
  end
end
