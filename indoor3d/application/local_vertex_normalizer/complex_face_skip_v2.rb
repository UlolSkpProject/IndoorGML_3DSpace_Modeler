# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Skips LocalVertexNormalizer before any operation or geometry mutation
      # when one source Face exceeds the inventory-backed polygon complexity
      # limits. Normal solids continue through the unchanged production path.
      module LocalVertexNormalizerComplexFaceSkipV2
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
          if commit_on_failure
            raise ArgumentError,
                  'commit_on_failure is disabled for LocalVertexNormalizer v2'
          end

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          skip_report = begin
            complex_face_skip_report_v2(entity)
          rescue StandardError
            nil
          end
          unless skip_report
            return super(
              entity,
              commit_on_failure: commit_on_failure,
              debug: debug,
              report: report,
              report_path: report_path,
              write_report: write_report,
              manage_operation: manage_operation,
              **options
            )
          end

          validate_entity!(entity)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
          skip_report[:elapsed_seconds] = elapsed
          attach_complex_face_skip_profile_v2(
            entity,
            skip_report,
            elapsed,
            debug: debug,
            report: report,
            report_path: report_path,
            write_report: write_report
          ) if debug == true || report == true
          skip_report
        end

        private

        def complex_face_skip_report_v2(entity)
          entities = entity.definition.entities
          inventory = complex_face_inventory_v2(entities)
          return nil if inventory[:complex_face_count].zero?

          topology = geometry_counts(entities)
          {
            normalization_complete: false,
            normalization_skipped: true,
            skip_scope: :solid,
            skip_reason: :complex_face_complexity_limit,
            normalization_strategy: :skipped_complex_face_preflight,
            geometry_unchanged: true,
            tolerance_mm: @tolerance_mm,
            manifold: entity.respond_to?(:manifold?) ? entity.manifold? == true :
              closed_topology?(topology),
            topology_before: topology,
            topology_after: topology.dup,
            face_count: inventory[:face_count],
            complex_face_count: inventory[:complex_face_count],
            complex_face_policy: complex_face_policy_v2,
            complex_faces: inventory[:complex_faces],
            max_face_complexity: inventory[:max_face_complexity]
          }
        end

        def complex_face_inventory_v2(entities)
          faces = entities.grep(@face_class).select do |face|
            !face.respond_to?(:valid?) || face.valid?
          end
          complex_faces = []
          complex_count = 0
          maxima = {
            weak_vertex_count: 0,
            inner_loop_count: 0,
            total_boundary_vertex_count: 0,
            bridge_candidate_estimate: 0,
            ear_work_estimate: 0
          }

          faces.each_with_index do |face, face_index|
            record = complex_face_record_v2(face, face_index)
            next unless record

            maxima.each_key do |key|
              maxima[key] = [maxima[key], record[key].to_i].max
            end
            next unless record[:complex]

            complex_count += 1
            if complex_faces.length <
               LocalVertexNormalizer::COMPLEX_FACE_REPORT_LIMIT
              complex_faces << record
            end
          end

          {
            face_count: faces.length,
            complex_face_count: complex_count,
            complex_faces: complex_faces,
            max_face_complexity: maxima
          }
        end

        def complex_face_record_v2(face, face_index)
          return nil unless face.respond_to?(:loops)

          loops = Array(face.loops)
          return nil if loops.empty?

          outer_loop = if face.respond_to?(:outer_loop)
                         face.outer_loop
                       else
                         loops.first
                       end
          ordered_loops = [outer_loop].compact + loops.reject do |loop|
            loop.equal?(outer_loop) || loop == outer_loop
          end
          loop_counts = ordered_loops.map do |loop|
            vertices = loop.respond_to?(:vertices) ? Array(loop.vertices) : []
            keys = vertices.map do |vertex|
              complex_face_grid_key_v2(vertex.position)
            end
            complex_face_compact_loop_v2(keys).length
          end
          outer_count = loop_counts.first.to_i
          hole_counts = loop_counts.drop(1)
          total_boundary = outer_count + hole_counts.sum
          weak_vertices = total_boundary + (2 * hole_counts.length)
          bridge_candidates = complex_face_bridge_work_v2(
            outer_count,
            hole_counts
          )
          ear_work = weak_vertices * weak_vertices

          reasons = []
          reasons << :weak_vertex_limit if
            weak_vertices > LocalVertexNormalizer::COMPLEX_FACE_WEAK_VERTEX_LIMIT
          reasons << :inner_loop_limit if
            hole_counts.length > LocalVertexNormalizer::COMPLEX_FACE_INNER_LOOP_LIMIT
          reasons << :total_boundary_vertex_limit if
            total_boundary >
              LocalVertexNormalizer::COMPLEX_FACE_TOTAL_BOUNDARY_VERTEX_LIMIT
          reasons << :ear_work_limit if
            ear_work > LocalVertexNormalizer::COMPLEX_FACE_EAR_WORK_LIMIT

          {
            face_index: face_index,
            face_key: stable_entity_id(face),
            loop_count: ordered_loops.length,
            inner_loop_count: hole_counts.length,
            outer_vertex_count: outer_count,
            hole_vertex_count: hole_counts.sum,
            total_boundary_vertex_count: total_boundary,
            weak_vertex_count: weak_vertices,
            bridge_candidate_estimate: bridge_candidates,
            ear_work_estimate: ear_work,
            complex: !reasons.empty?,
            reasons: reasons
          }
        rescue StandardError => error
          {
            face_index: face_index,
            face_key: stable_entity_id(face),
            complex: true,
            reasons: [:complexity_analysis_error],
            error: "#{error.class}: #{error.message}"
          }
        end

        def complex_face_grid_key_v2(point)
          [point.x, point.y, point.z].map do |coordinate|
            ((coordinate.to_f * LocalVertexNormalizer::MM_PER_INCH) / @tolerance_mm).round
          end
        end

        def complex_face_compact_loop_v2(keys)
          compact = []
          Array(keys).each do |key|
            compact << key if compact.empty? || compact.last != key
          end
          compact.pop if compact.length > 1 && compact.first == compact.last
          compact
        end

        def complex_face_bridge_work_v2(outer_count, hole_counts)
          polygon_count = outer_count
          candidates = 0
          Array(hole_counts).each do |hole_count|
            candidates += polygon_count
            polygon_count += hole_count + 2
          end
          candidates
        end

        def complex_face_policy_v2
          {
            weak_vertex_limit:
              LocalVertexNormalizer::COMPLEX_FACE_WEAK_VERTEX_LIMIT,
            inner_loop_limit:
              LocalVertexNormalizer::COMPLEX_FACE_INNER_LOOP_LIMIT,
            total_boundary_vertex_limit:
              LocalVertexNormalizer::COMPLEX_FACE_TOTAL_BOUNDARY_VERTEX_LIMIT,
            ear_work_limit:
              LocalVertexNormalizer::COMPLEX_FACE_EAR_WORK_LIMIT
          }
        end

        def attach_complex_face_skip_profile_v2(
          entity,
          skip_report,
          elapsed,
          debug:,
          report:,
          report_path:,
          write_report:
        )
          geometry = debug_geometry_counts(entity)
          profile = {
            enabled: true,
            verbose: debug == true && report != true,
            report_enabled: report == true,
            entity: debug_entity_label(entity),
            persistent_id: debug_entity_persistent_id(entity),
            tolerance_mm: @tolerance_mm,
            geometry_before: geometry,
            geometry_after: geometry.dup,
            status: :skipped,
            total_seconds: elapsed,
            events: [
              {
                stage: :complex_face_preflight,
                status: :skipped,
                seconds: elapsed,
                started_after_seconds: 0.0,
                details: {
                  complex_face_count: skip_report[:complex_face_count],
                  skip_reason: skip_report[:skip_reason]
                }
              }
            ],
            stages: {
              complex_face_preflight: {
                calls: 1,
                total_seconds: elapsed,
                max_seconds: elapsed,
                failures: 0
              }
            },
            snapshot_roles: {},
            normalization_skipped: true,
            skip_reason: skip_report[:skip_reason],
            complex_face_count: skip_report[:complex_face_count],
            complex_face_policy: skip_report[:complex_face_policy],
            complex_faces: skip_report[:complex_faces]
          }
          self.class.last_debug_profile = profile if
            self.class.respond_to?(:last_debug_profile=)

          if profile[:verbose]
            puts format(
              '[LVN DEBUG] PROFILE SKIPPED total=%.6fs reason=%s complex_faces=%d',
              elapsed,
              skip_report[:skip_reason],
              skip_report[:complex_face_count]
            )
          end

          if report == true && write_report
            written_path = self.class.write_timing_report(
              single_solid_timing_report(profile),
              report_path: report_path,
              entity: entity,
              prefix: 'local_vertex_normalization'
            )
            profile[:report_path] = written_path
            skip_report[:timing_report_path] = written_path
            puts format(
              '[LVN REPORT] SKIPPED total=%.6fs path=%s',
              elapsed,
              written_path
            )
          end
          skip_report[:debug_profile] = profile
        end
      end

      class LocalVertexNormalizer
        COMPLEX_FACE_WEAK_VERTEX_LIMIT = 512 unless
          const_defined?(:COMPLEX_FACE_WEAK_VERTEX_LIMIT, false)
        COMPLEX_FACE_INNER_LOOP_LIMIT = 32 unless
          const_defined?(:COMPLEX_FACE_INNER_LOOP_LIMIT, false)
        COMPLEX_FACE_TOTAL_BOUNDARY_VERTEX_LIMIT = 1_024 unless
          const_defined?(:COMPLEX_FACE_TOTAL_BOUNDARY_VERTEX_LIMIT, false)
        COMPLEX_FACE_EAR_WORK_LIMIT = 500_000 unless
          const_defined?(:COMPLEX_FACE_EAR_WORK_LIMIT, false)
        COMPLEX_FACE_REPORT_LIMIT = 16 unless
          const_defined?(:COMPLEX_FACE_REPORT_LIMIT, false)

        prepend LocalVertexNormalizerComplexFaceSkipV2 unless
          ancestors.include?(LocalVertexNormalizerComplexFaceSkipV2)
      end
    end
  end
end
